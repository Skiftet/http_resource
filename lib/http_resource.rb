# frozen_string_literal: true

require "http_resource/version"
require "http_resource/errors"
require "http_resource/auth"
require "http_resource/client"
require "http_resource/configuration"
require "http_resource/resource"
require "http_resource/value_object"

# A small, zero-dependency framework for building typed REST-resource clients on
# top of Net::HTTP. Bring a base_url + an auth strategy; get a Net::HTTP
# transport with a typed error hierarchy, bang/non-bang resources, per-call
# timeouts and escape-safe URL building.
#
# Build a client directly:
#
#   client = HttpResource::Client.new(base_url: "https://api.example.org",
#                                     auth: HttpResource::Auth.bearer(token))
#
# …or configure a process-wide default:
#
#   HttpResource.configure do |c|
#     c.base_url = ENV.fetch("API_URL")
#     c.auth = HttpResource::Auth.basic(ENV.fetch("API_USER"), ENV.fetch("API_PASS"))
#   end
#   HttpResource.client.get(["api", "ping"])
module HttpResource
  class << self
    # Configure the process-wide default client, then (re)build it.
    def configure
      yield configuration
      @client = build_client
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # The memoized default client, built from `configuration`.
    def client
      @client ||= build_client
    end

    # Build a fresh, independent client. Defaults to the configured base_url/auth,
    # but every option can be overridden per call — handy for talking to more
    # than one host without a global default.
    def build_client(base_url: configuration.base_url, auth: configuration.auth,
                     open_timeout: configuration.open_timeout, read_timeout: configuration.read_timeout)
      Client.new(base_url:, auth:, open_timeout:, read_timeout:)
    end

    # Drop the memoized config + client (mainly for tests / reconfiguration).
    def reset!
      @configuration = nil
      @client = nil
    end
  end
end
