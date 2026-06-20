# frozen_string_literal: true

module HttpResource
  module Auth
    # Bearer-token auth: sets `Authorization: Bearer <token>`.
    class Bearer
      def initialize(token)
        @token = token.to_s
      end

      def apply(request)
        request["Authorization"] = "Bearer #{@token}"
      end
    end
  end
end
