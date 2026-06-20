# frozen_string_literal: true

module HttpResource
  # Mixin for response value objects, designed to pair with Ruby's Data.define.
  # It gives a class a tolerant `.from(payload)` that:
  #   - returns nil for a nil payload (so an empty 2xx -> nil, never a ghost),
  #   - unwraps a top-level { "data" => {...} } envelope if present,
  #   - normalises string OR symbol keys,
  # then hands the inner hash to `build` (or the Data.define member names, when
  # no `build` is defined) so missing keys arrive as nil instead of raising.
  #
  #   Contact = Data.define(:email, :name) do
  #     extend HttpResource::ValueObject
  #   end
  #   Contact.from("data" => { "email" => "a@b.se" })  # => #<data Contact email="a@b.se", name=nil>
  #   Contact.from(nil)                                 # => nil
  #
  # Resource methods should still guard `data && Contact.from(data)` so the
  # caller never receives a ghost object from an empty body.
  module ValueObject
    def from(payload)
      return nil if payload.nil?

      data = unwrap(payload)
      respond_to?(:build) ? build(data) : new(**slice_members(data))
    end

    private

    def unwrap(payload)
      hash = stringify(payload)
      inner = hash["data"]
      inner.is_a?(Hash) ? inner : hash
    end

    def stringify(payload)
      return {} unless payload.is_a?(Hash)

      payload.transform_keys(&:to_s)
    end

    # Pick exactly the Data members, defaulting missing ones to nil.
    def slice_members(data)
      members.to_h { |key| [key, data[key.to_s]] }
    end
  end
end
