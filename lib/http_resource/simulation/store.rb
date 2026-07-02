# frozen_string_literal: true

module HttpResource
  module Simulation
    # Per-Backend in-memory record store. Collection-agnostic: ANY name
    # auto-vivifies an empty collection on first access. Records are Hashes
    # with STRING keys — they stand in for parsed JSON, so the value objects
    # and resource proxies above read them exactly as they would a live
    # response body.
    class Store
      def initialize
        @collections = Hash.new { |hash, key| hash[key] = [] }
        @sequences = Hash.new(0)
      end

      # store[:contacts] — the collection's Array (auto-vivified, live
      # reference: handlers mutate it in place).
      def [](collection)
        @collections[collection.to_sym]
      end

      # Allocate the next Integer id for a collection. MUTATING — every call
      # consumes an id. Never call it from a test assertion; read the
      # records' "id" values instead.
      def next_id(collection)
        @sequences[collection.to_sym] += 1
      end

      # Append records under ANY collection names, assigning "id" via next_id
      # when absent: seed(contacts: [...], "invoices" => [...]). Symbol- or
      # string-keyed records; all keys are normalized (deeply) to strings.
      def seed(collections)
        collections.each do |name, records|
          unless records.is_a?(Array)
            raise ArgumentError,
                  "records for #{name.inspect} must be an Array of Hashes, got #{records.class}"
          end

          records.each { append(name, _1) }
        end
        nil
      end

      # Clears the collections IN PLACE, so previously-obtained collection
      # references (see #[]) stay live across a reset.
      def reset!
        @collections.each_value(&:clear)
        @sequences.clear
        nil
      end

      # Public because handlers need the same JSON-shaping for records they
      # build from request payloads.
      def deep_stringify(value)
        case value
        when Hash then value.to_h { |key, val| [key.to_s, deep_stringify(val)] }
        when Array then value.map { deep_stringify(_1) }
        else value
        end
      end

      private

      def append(collection, record)
        record = deep_stringify(record)
        if record["id"]
          reserve_id(collection, record["id"])
        else
          record["id"] = next_id(collection)
        end
        self[collection] << record
      end

      # An explicitly seeded id is RESERVED: it must be unique within its
      # collection — compared as STRINGS, the way handlers look ids up from
      # path segments — and a duplicate is a test-authoring bug that raises.
      # The sequence advances past integer-LIKE ids (5 and "5" alike) so a
      # later next_id can never hand out an id that aliases a reserved one.
      # Non-numeric String ids (UUIDs…) are kept as-is.
      def reserve_id(collection, id)
        raise ArgumentError, "duplicate id #{id.inspect} in #{collection.inspect}" if
          self[collection].any? { _1["id"].to_s == id.to_s }

        key = collection.to_sym
        @sequences[key] = [@sequences[key], id.to_i].max if id.to_s.match?(/\A\d+\z/)
      end
    end
  end
end
