# frozen_string_literal: true

require "http_resource"
require "webmock/rspec"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  config.after { HttpResource.reset! }
end

# A minimal resource used by several specs to exercise the bang/non-bang +
# value-object pattern against WebMock stubs.
module SpecSupport
  Contact = Data.define(:email, :name) do
    extend HttpResource::ValueObject
  end

  class Contacts < HttpResource::Resource
    def find(id) = soft { find!(id) }

    def find!(id)
      data = @client.get(["api", "contacts", id])
      data && Contact.from(data)
    end

    def create(attrs) = soft { create!(attrs) }

    def create!(attrs)
      data = @client.post(%w[api contacts], attrs)
      data && Contact.from(data)
    end
  end
end
