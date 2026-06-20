# frozen_string_literal: true

module HttpResource
  # Base for the REST resource proxies hung off a Client. A subclass maps one
  # endpoint to its verbs in a bang/non-bang pair (Rails-style):
  #
  #   find(id)   — returns the value object, or nil on an EXPECTED miss (404
  #                not-found). Raises on the UNEXPECTED (validation, auth, 5xx,
  #                timeout, connection).
  #   find!(id)  — raises an HttpResource::ApiError on ANY failure.
  #
  # Sketch:
  #
  #   class Contacts < HttpResource::Resource
  #     def find(id)  = soft { find!(id) }
  #     def find!(id)
  #       data = @client.get(["api", "contacts", id])
  #       data && Contact.from(data)
  #     end
  #   end
  class Resource
    def initialize(client)
      @client = client
    end

    private

    # Run the bang form, swallowing only EXPECTED failures (404) to nil.
    def soft
      yield
    rescue Expected
      nil
    end
  end
end
