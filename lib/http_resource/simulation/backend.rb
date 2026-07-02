# frozen_string_literal: true

require "json"
require "uri"
require "http_resource/errors"
require "http_resource/simulation/store"

module HttpResource
  module Simulation
    # In-memory stand-in for Client's transport. Same verb surface (signatures
    # including params:/form:/timeouts), same deterministic-bug guards, and it
    # answers with parsed-JSON-shaped Hashes (string keys) or nil, or raises
    # via ApiError.for_status — so every resource proxy, value object and
    # error path above it runs UNCHANGED against seeded in-memory state.
    #
    # Client gems SUBCLASS Backend and let handlers self-register on the
    # subclass at file load:
    #
    #   class MyGem::Simulation::Backend < HttpResource::Simulation::Backend; end
    #   MyGem::Simulation::Backend.register("api/contacts", ContactsHandler)
    #
    # Each subclass owns its OWN registry (one gem's handlers can never leak
    # into another's); lookup walks the inheritance chain — the NEAREST class
    # with any matching prefix wins (a subclass registration shadows the
    # parent's wholesale), longest whole-segment prefix within that class.
    # Handlers are HandlerClass.new(store), memoized per backend instance, and
    # receive handler.call(verb, segments, payload:, params:).
    class Backend
      class << self
        def register(prefix, handler_class)
          registry[prefix_segments(prefix)] = handler_class
        end

        # This class's OWN registrations ({segments => handler_class}), NOT
        # including inherited ones — dispatch walks the ancestry explicitly.
        def registry
          @registry ||= {}
        end

        private

        def prefix_segments(prefix)
          prefix.to_s.gsub(%r{\A/+|/+\z}, "").split("/").freeze
        end
      end

      attr_reader :store

      def initialize
        @store = Store.new
        @handlers = {}
        @injections = []
      end

      # The timeout kwargs are accepted AND ignored on purpose: the surface
      # must match Client's verbs exactly so calling code runs unchanged.
      # rubocop:disable Lint/UnusedMethodArgument
      def get(path, params: nil, open_timeout: nil, read_timeout: nil)
        dispatch(:get, path, params: normalize_params(params))
      end

      def post(path, payload = nil, form: nil, open_timeout: nil, read_timeout: nil)
        dispatch(:post, path, payload:, form:)
      end

      def put(path, payload = nil, form: nil, open_timeout: nil, read_timeout: nil)
        dispatch(:put, path, payload:, form:)
      end

      def patch(path, payload = nil, form: nil, open_timeout: nil, read_timeout: nil)
        dispatch(:patch, path, payload:, form:)
      end

      def delete(path, open_timeout: nil, read_timeout: nil)
        dispatch(:delete, path)
      end
      # rubocop:enable Lint/UnusedMethodArgument

      def seed(collections)
        @store.seed(collections)
      end

      # Queue a one-shot failure: the next call whose normalized path contains
      # `on:` (any call when omitted) raises the mapped ApiError, then the
      # injection is consumed. Non-matching injections are skipped over and
      # STAY queued (FIFO among matches). `body:` is coerced to the String a
      # real transport error carries (a Hash/Array is JSON-encoded).
      def fail_next(status:, body: nil, on: nil)
        @injections << { status:, body: string_body(body), on: normalize_on(on) }
        nil
      end

      def reset!
        @store.reset!
        @handlers.clear
        @injections.clear
        nil
      end

      private

      # Guard order mirrors production exactly: path first (build_uri), body
      # second (build_request), only then the "network" (injections + handler)
      # — so a doubly-broken call raises the SAME error in both modes.
      def dispatch(verb, path, payload: nil, form: nil, params: nil)
        segments = normalize_path(path)
        body = body_for(payload, form)
        consume_injection!(segments.join("/"))

        prefix, handler_class = match(segments)
        unless handler_class
          raise ApiError.for_status("no simulation handler for #{verb.to_s.upcase} /#{segments.join('/')}",
                                    status: 501, body: nil)
        end

        # Memoized on the RESOLVED class (not the prefix), so a same-prefix
        # registration on a nearer class can never serve a stale instance.
        handler = (@handlers[handler_class] ||= handler_class.new(@store))
        result = handler.call(verb, segments.drop(prefix.size), payload: body, params:)
        # The response is a FRESH parsed-JSON copy, like a real body parse:
        # callers can't corrupt the store by mutating it, and a handler's
        # symbol keys are normalized to the contract's string keys.
        result.nil? ? nil : JSON.parse(JSON.generate(result))
      end

      # Same guard as the real transport (Client#apply_body), and the payload
      # reaches the handler the way a REAL server would see it: a JSON payload
      # as its parsed-JSON form (string keys; an unserializable payload raises
      # JSON::GeneratorError exactly like the real build_request), a form
      # payload as the string pairs a form decoder yields (values to_s'd,
      # repeated keys last-wins, matching a bare-key Rack parse).
      def body_for(payload, form)
        raise ArgumentError, "pass either a JSON payload or form:, not both" if payload && form

        if form
          URI.decode_www_form(URI.encode_www_form(form)).to_h
        elsif payload
          JSON.parse(JSON.generate(payload))
        end
      end

      # Array segments arrive raw (the backend replaces the transport BEFORE
      # any percent-encoding) but pass the SAME validation as the real
      # encoder: blank and dot-segments are caller bugs there and stay caller
      # bugs here. A String path may carry encoded bytes, so its segments are
      # decoded to what a server-side router sees; a malformed %-escape raises
      # URI::InvalidURIError, exactly as the real URI build would.
      def normalize_path(path)
        if path.is_a?(Array)
          path.map { validate_segment(_1) }
        else
          stripped = path.to_s.gsub(%r{\A/+|/+\z}, "")
          validate_string_path(stripped)
          stripped.split("/").map { decode_segment(_1) }
        end
      end

      # Parity: the real transport URI.parses the String path, so a
      # URI-invalid character (raw space, "|", a malformed %-escape, …) raises
      # URI::InvalidURIError there — it must raise here too. Note simulation
      # treats a String as a PURE path (no query/fragment splitting).
      def validate_string_path(stripped)
        URI.parse("http://sim.invalid/#{stripped}")
      rescue URI::InvalidURIError
        raise URI::InvalidURIError, "invalid String path for simulation: #{stripped.inspect}"
      end

      # Query params reach the handler the way a real server sees them:
      # string pairs (repeated keys last-wins), with an empty hash — which
      # produces no query string on the wire — converging to nil, exactly
      # like build_uri's `params && !params.empty?` guard.
      def normalize_params(params)
        return nil if params.nil? || params.empty?

        URI.decode_www_form(URI.encode_www_form(params)).to_h
      end

      def validate_segment(segment)
        str = segment.to_s
        raise ArgumentError, "path segment may not be blank" if str.empty?
        raise ArgumentError, "path segment may not be a '.' or '..' dot-segment" if [".", ".."].include?(str)

        str
      end

      def decode_segment(segment)
        URI.decode_uri_component(segment)
      rescue ArgumentError
        raise URI::InvalidURIError, "malformed percent-encoding in path segment #{segment.inspect}"
      end

      # Nearest class with ANY match wins; longest prefix within that class.
      def match(segments)
        klass = self.class
        while klass.respond_to?(:registry)
          hit = klass.registry
                     .select { |prefix, _| segments.first(prefix.size) == prefix }
                     .max_by { |prefix, _| prefix.size }
          return hit if hit

          klass = klass.superclass
        end
        nil
      end

      def consume_injection!(joined_path)
        index = @injections.index { _1[:on].nil? || joined_path.include?(_1[:on]) }
        return unless index

        injection = @injections.delete_at(index)
        raise ApiError.for_status("injected failure", status: injection[:status], body: injection[:body])
      end

      def normalize_on(on)
        on&.to_s&.gsub(%r{\A/+|/+\z}, "")
      end

      def string_body(body)
        return body if body.nil? || body.is_a?(String)

        JSON.generate(body)
      end
    end
  end
end
