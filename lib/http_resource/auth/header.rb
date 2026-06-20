# frozen_string_literal: true

module HttpResource
  module Auth
    # Arbitrary-header auth: sets a custom header (e.g. `X-Api-Key: <value>`).
    class Header
      def initialize(name, value)
        @name = name.to_s
        @value = value.to_s
      end

      def apply(request)
        request[@name] = @value
      end
    end
  end
end
