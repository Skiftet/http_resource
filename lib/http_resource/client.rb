# frozen_string_literal: true

require "net/http"
require "uri"
require "erb"
require "json"
require "openssl"

module HttpResource
  # Net::HTTP transport for a single REST host. Resource-oriented: the verbs
  # (get/post/put/patch/delete) are the primitives a Resource is built on, and
  # also an escape hatch for endpoints not yet modelled.
  #
  #   client = HttpResource::Client.new(base_url: "https://api.example.org",
  #                                     auth: HttpResource::Auth.bearer(token))
  #   client.get(["api", "contacts", id])            # GET, id escaped as one segment
  #   client.post(["api", "actions"], { ... })       # POST a JSON body
  #   client.post(["oauth", "token"], form: { ... }) # POST a form body (OAuth, RFC 6749)
  #
  # Reads return parsed JSON (a Hash/Array, or nil on an empty body). Every call
  # raises an HttpResource::ApiError subclass on a non-2xx response or a transport
  # failure.
  #
  # SECURITY — path segments are UNTRUSTED. When `path` is an Array, each segment
  # is percent-encoded as a single RFC-3986 path component, so an id/email/token
  # can never escape into a second segment, the host, a query or a header. A
  # String `path` is sent VERBATIM (trusted) — NEVER interpolate untrusted input
  # into a String path; pass an Array.
  class Client
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 15

    attr_reader :base_url

    # The simulation backend when built with simulation:; nil in real mode.
    attr_reader :simulation

    # The Backend class `simulation: true` instantiates. Client-gem subclasses
    # override this to point at their own Backend subclass (with its own
    # registered handlers). Only called after the lazy require, so the
    # constant resolves.
    def self.simulation_backend_class
      Simulation::Backend
    end

    def initialize(base_url:, auth: nil, username: nil, password: nil,
                   open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT,
                   simulation: nil)
      raise ConfigurationError, "base_url is required" if blank?(base_url)

      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @auth = auth || default_auth(username, password)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @simulation = setup_simulation(simulation)
    end

    # Low-level REST verbs. `path` may be a String ("/api/foo") sent verbatim, or
    # an Array of segments (["api", "contacts", email]) each individually escaped.
    # Each verb accepts open_timeout:/read_timeout: to override the client's
    # budget for that one call (e.g. a short read_timeout on a synchronous read).
    #
    # The body-bearing verbs (post/put/patch) send EITHER a JSON body — the
    # positional `payload` — or a form body — `form: {...}`, encoded as
    # application/x-www-form-urlencoded (for the form-encoded endpoints OAuth
    # consumers hit: RFC 6749 token, RFC 7662 introspection, …). Passing both is
    # a caller bug and raises ArgumentError. The response side is identical either
    # way: parsed JSON on a 2xx, a typed ApiError (with #status + #body) on a
    # non-2xx — so a "400 invalid_grant" is a rescue-able ClientError whose #body
    # carries the error payload.
    def get(path, params: nil, open_timeout: nil, read_timeout: nil)
      request(:get, path, params:, open_timeout:, read_timeout:)
    end

    def post(path, payload = nil, form: nil, open_timeout: nil, read_timeout: nil)
      request(:post, path, body: payload, form:, open_timeout:, read_timeout:)
    end

    def put(path, payload = nil, form: nil, open_timeout: nil, read_timeout: nil)
      request(:put, path, body: payload, form:, open_timeout:, read_timeout:)
    end

    def patch(path, payload = nil, form: nil, open_timeout: nil, read_timeout: nil)
      request(:patch, path, body: payload, form:, open_timeout:, read_timeout:)
    end

    def delete(path, open_timeout: nil, read_timeout: nil)
      request(:delete, path, open_timeout:, read_timeout:)
    end

    private

    def request(method, path, body: nil, form: nil, params: nil, open_timeout: nil, read_timeout: nil)
      # In simulation the verb call is handed to the backend BEFORE any URI
      # build or network I/O — the backend enforces the same deterministic-bug
      # guards, so a call that raises in production raises identically here.
      return simulate(method, path, body:, form:, params:) if @simulation

      # Build the URI + request OUTSIDE the network rescue: a URI::InvalidURIError
      # (bad path), JSON::GeneratorError (un-serializable payload, e.g. a NaN
      # amount) or an ArgumentError (both a JSON and a form body) is a
      # deterministic caller bug, and must NOT be masked as a retryable
      # TransportError — that would have a worker retry it forever.
      uri = build_uri(path, params)
      req = build_request(method, uri, body, form)
      connection = http(uri, open_timeout:, read_timeout:)
      begin
        handle(connection.request(req))
      rescue ApiError
        raise
      rescue Timeout::Error, Errno::ETIMEDOUT => e # Net::Open/ReadTimeout subclass Timeout::Error
        raise TimeoutError, "Request timed out: #{e.class}: #{e.message}"
      rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
        raise ConnectionError, "Connection failed: #{e.class}: #{e.message}"
      rescue StandardError => e
        raise TransportError, "Request failed: #{e.class}: #{e.message}"
      end
    end

    # An Array path has each segment percent-encoded as ONE path component
    # (RFC 3986). ERB::Util.url_encode encodes "/", "?", "#", ":", "@", ";",
    # CR/LF, space (as %20, not "+") and every reserved char — so an untrusted
    # segment cannot introduce a new path segment, change the host, or inject a
    # query/fragment/CRLF. A String path is trusted and sent verbatim.
    def build_uri(path, params)
      joined =
        if path.is_a?(Array)
          path.map { encode_segment(_1) }.join("/")
        else
          path.to_s.sub(%r{\A/+}, "")
        end
      uri = URI.parse("#{@base_url}/#{joined}")
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      uri
    end

    # Percent-encode one untrusted path segment as a single RFC-3986 path
    # component. Two inputs can't be safely encoded and must be REJECTED:
    #   - a BLANK segment would collapse into "//".
    #   - "." / ".." are dot-segments a server/proxy resolves to climb the path,
    #     and NO percent-encoding survives strict normalisation (%2E decodes back
    #     to "." per RFC 3986 §6.2.2.2, THEN remove_dot_segments traverses). No
    #     legitimate id is a dot-segment, so reject rather than (uselessly) encode.
    def encode_segment(segment)
      str = segment.to_s
      raise ArgumentError, "path segment may not be blank" if str.empty?
      raise ArgumentError, "path segment may not be a '.' or '..' dot-segment" if [".", ".."].include?(str)

      ERB::Util.url_encode(str)
    end

    def build_request(method, uri, body, form = nil)
      klass = {
        get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put,
        patch: Net::HTTP::Patch, delete: Net::HTTP::Delete
      }.fetch(method)
      request = klass.new(uri)
      @auth&.apply(request)
      request["Accept"] = "application/json"
      apply_body(request, body, form)
      request
    end

    # A request carries EITHER a JSON body (`payload`) or a form body (`form:`),
    # never both — passing both is a caller bug. Form values are percent-encoded
    # by URI.encode_www_form (the same encoder used for query params), so an
    # untrusted key/value can't inject a header, a second field, or CRLF.
    def apply_body(request, body, form)
      raise ArgumentError, "pass either a JSON payload or form:, not both" if body && form

      if form
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(form)
      elsif body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
    end

    def http(uri, open_timeout: nil, read_timeout: nil)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = open_timeout || @open_timeout
      http.read_timeout = read_timeout || @read_timeout
      http
    end

    def handle(response)
      status = response.code.to_i
      body = response.body.to_s
      parsed = body.empty? ? nil : parse_json(body)
      return parsed if status.between?(200, 299)

      raise ApiError.for_status("HTTP request returned #{status}", status:, body:)
    end

    def parse_json(body)
      JSON.parse(body)
    rescue JSON::JSONError
      body
    end

    def simulate(method, path, body:, form:, params:)
      # The public verbs only pass params: on get; reaching this with params
      # on another verb means private-seam misuse — fail loud, don't drop it.
      raise ArgumentError, "params: is only supported on get in simulation" if params && method != :get

      case method
      when :get then @simulation.get(path, params:)
      when :delete then @simulation.delete(path)
      else @simulation.public_send(method, path, body, form:)
      end
    end

    # Lazy: the simulation machinery is test-facing and never loaded unless
    # asked for — plain `require "http_resource"` must not pull it in.
    def setup_simulation(simulation)
      return nil unless simulation

      require "http_resource/simulation"
      simulation == true ? self.class.simulation_backend_class.new : simulation
    end

    def default_auth(username, password)
      return nil if blank?(username) && blank?(password)

      Auth::Basic.new(username, password)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
