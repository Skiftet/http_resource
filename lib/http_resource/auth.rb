# frozen_string_literal: true

require "http_resource/auth/basic"
require "http_resource/auth/bearer"
require "http_resource/auth/header"

module HttpResource
  # Pluggable auth strategies. A strategy is any object responding to
  # `#apply(request)` that mutates a Net::HTTP request to carry credentials.
  # Three are shipped (Basic, Bearer, Header); bring your own for anything else.
  module Auth
    # Convenience builders so callers can write `Auth.basic("u", "p")`.

    module_function

    def basic(username, password)
      Basic.new(username, password)
    end

    def bearer(token)
      Bearer.new(token)
    end

    def header(name, value)
      Header.new(name, value)
    end
  end
end
