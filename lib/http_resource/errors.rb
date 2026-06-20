# frozen_string_literal: true

module HttpResource
  # Base for every error the framework raises.
  class Error < StandardError; end

  # Missing/blank base_url, or other misconfiguration of a client.
  class ConfigurationError < Error; end

  # Marker for the ONE failure the non-bang resource methods (find, destroy)
  # treat as an EXPECTED outcome and swallow to nil: a 404 not-found. Everything
  # else — INCLUDING a 422 validation rejection on a write (which must surface,
  # not silently drop the write) — is UNEXPECTED and raises even from the
  # non-bang form. The bang form (find!, create!) raises on any failure.
  module Expected; end

  # Raised on a non-2xx response or a transport failure. Carries the HTTP status
  # (an Integer, or nil for transport failures) + the raw body, so a background
  # worker can branch its retry: drop on a 4xx (client_error?), retry on a 5xx
  # (server_error?) or a transport failure (TransportError, status nil).
  class ApiError < Error
    attr_reader :status, :body

    def initialize(message = nil, status: nil, body: nil)
      @status = status
      @body = body
      super(message || "HTTP error (status=#{status.inspect})")
    end

    def client_error?
      status.is_a?(Integer) && status.between?(400, 499)
    end

    def server_error?
      status.is_a?(Integer) && status.between?(500, 599)
    end

    def not_found?
      status == 404
    end

    # Map an HTTP status to the most specific ApiError subclass.
    def self.for_status(message, status:, body:)
      klass =
        case status
        when 404 then NotFoundError
        when 422 then ValidationError
        when 401, 403 then AuthError
        when 400..499 then ClientError
        when 300..399 then RedirectError
        when 500..599 then ServerError
        else self
        end
      klass.new(message, status:, body:)
    end
  end

  # 4xx — the caller's request won't succeed on retry; a background worker should
  # drop, not retry. Parent of the specific 4xx below.
  class ClientError < ApiError; end

  # 404 — the resource does not exist. Expected: the non-bang form swallows it to nil.
  class NotFoundError < ClientError
    include Expected
  end

  # 422 — the request was rejected as invalid (the body holds the details). NOT
  # Expected: a non-bang write raises this instead of silently dropping the
  # write, so a sync job surfaces and retries the failure rather than losing data.
  class ValidationError < ClientError; end

  # 401/403 — bad or missing credentials. Almost always a config problem; raises
  # even from the non-bang form.
  class AuthError < ClientError; end

  # 3xx — the server returned a redirect (Net::HTTP does not follow them). Almost
  # always a misconfigured base_url (e.g. http:// hitting an https redirect); not
  # retryable. Neither client_error? nor server_error?.
  class RedirectError < ApiError; end

  # 5xx — the server failed to handle a valid request. Retryable.
  class ServerError < ApiError; end

  # Network-level failure before/while talking to the server; status is nil. Retryable.
  class TransportError < ApiError; end

  # The connection or read exceeded the timeout budget.
  class TimeoutError < TransportError; end

  # Could not establish/keep the connection (refused, reset, DNS, TLS).
  class ConnectionError < TransportError; end
end
