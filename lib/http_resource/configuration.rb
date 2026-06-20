# frozen_string_literal: true

module HttpResource
  # Holds the settings for building a default client (HttpResource.client).
  # Framework-generic: no app-specific env names. A host sets these explicitly in
  # an initializer, mapping ITS own env vars onto them.
  #
  #   HttpResource.configure do |c|
  #     c.base_url = ENV.fetch("API_URL")
  #     c.auth = HttpResource::Auth.bearer(ENV.fetch("API_TOKEN"))
  #   end
  class Configuration
    attr_accessor :base_url, :auth, :open_timeout, :read_timeout

    def initialize
      @base_url = nil
      @auth = nil
      @open_timeout = Client::DEFAULT_OPEN_TIMEOUT
      @read_timeout = Client::DEFAULT_READ_TIMEOUT
    end
  end
end
