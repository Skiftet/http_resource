# frozen_string_literal: true

require "net/http"
require "uri"
require "erb"
require "json"
require "openssl"

module HttpResource
  # Net::HTTP transport for a single REST host. Resource-oriented: the verbs
  # (get/post/patch/delete) are the primitives a Resource is built on, and also
  # an escape hatch for endpoints not yet modelled.
  #
  #   client = HttpResource::Client.new(base_url: "https://api.example.org",
  #                                     auth: HttpResource::Auth.bearer(token))
  #   client.get(["api", "contacts", id])         # GET, id escaped as one segment
  #   client.post(["api", "actions"], { ... })    # POST a JSON body
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

    def initialize(base_url:, auth: nil, username: nil, password: nil,
                   open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
      raise ConfigurationError, "base_url is required" if blank?(base_url)

      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @auth = auth || default_auth(username, password)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Low-level REST verbs. `path` may be a String ("/api/foo") sent verbatim, or
    # an Array of segments (["api", "contacts", email]) each individually escaped.
    # Each verb accepts open_timeout:/read_timeout: to override the client's
    # budget for that one call (e.g. a short read_timeout on a synchronous read).
    def get(path, params: nil, **timeouts)
      request(:get, path, params:, **timeouts)
    end

    def post(path, payload = nil, **timeouts)
      request(:post, path, body: payload, **timeouts)
    end

    def patch(path, payload = nil, **timeouts)
      request(:patch, path, body: payload, **timeouts)
    end

    def delete(path, **timeouts)
      request(:delete, path, **timeouts)
    end

    private

    def request(method, path, body: nil, params: nil, open_timeout: nil, read_timeout: nil)
      # Build the URI + request OUTSIDE the network rescue: a URI::InvalidURIError
      # (bad path) or JSON::GeneratorError (un-serializable payload, e.g. a NaN
      # amount) is a deterministic caller bug, and must NOT be masked as a
      # retryable TransportError — that would have a worker retry it forever.
      uri = build_uri(path, params)
      req = build_request(method, uri, body)
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

    def build_request(method, uri, body)
      klass = {
        get: Net::HTTP::Get, post: Net::HTTP::Post,
        patch: Net::HTTP::Patch, delete: Net::HTTP::Delete
      }.fetch(method)
      request = klass.new(uri)
      @auth&.apply(request)
      request["Accept"] = "application/json"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      request
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

    def default_auth(username, password)
      return nil if blank?(username) && blank?(password)

      Auth::Basic.new(username, password)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
