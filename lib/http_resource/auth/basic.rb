# frozen_string_literal: true

module HttpResource
  module Auth
    # HTTP Basic auth: sets the standard `Authorization: Basic <base64>` header
    # via Net::HTTP's own `#basic_auth`.
    class Basic
      def initialize(username, password)
        @username = username.to_s
        @password = password.to_s
      end

      def apply(request)
        request.basic_auth(@username, @password)
      end
    end
  end
end
