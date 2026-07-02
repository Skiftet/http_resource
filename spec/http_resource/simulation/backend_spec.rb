# frozen_string_literal: true

require "http_resource/simulation"

RSpec.describe HttpResource::Simulation::Backend do
  # Anonymous subclasses give every example its OWN registry — per-subclass
  # isolation is the design, so no snapshot/restore dance is needed.
  let(:backend_class) { Class.new(described_class) }
  subject(:backend) { backend_class.new }

  # A minimal handler that echoes what it was called with and counts its
  # calls, so specs can observe dispatch arguments, memoization and state.
  let(:echo_handler) do
    Class.new do
      attr_reader :store

      def initialize(store)
        @store = store
        @calls = 0
      end

      def call(verb, segments, payload:, params:)
        @calls += 1
        { "verb" => verb.to_s, "segments" => segments, "payload" => payload,
          "params" => params, "calls" => @calls }
      end
    end
  end

  def answering(answer)
    Class.new do
      define_method(:initialize) { |_store| nil }
      define_method(:call) { |*, **| { "matched" => answer } }
    end
  end

  describe ".register + dispatch" do
    it "routes a call to the handler registered for the path's prefix" do
      backend_class.register("api/echo", echo_handler)

      response = backend.get("/api/echo/42", params: { limit: 4 })

      expect(response).to include("verb" => "get", "segments" => ["42"], "params" => { "limit" => "4" })
    end

    it "normalizes a registered prefix like a path (slashes tolerated)" do
      backend_class.register("/api/echo/", answering("x"))

      expect(backend.get("/api/echo/1")).to eq({ "matched" => "x" })
    end

    it "picks the LONGEST matching prefix regardless of registration order" do
      backend_class.register("api", answering("shallow"))
      backend_class.register("api/echo", answering("deep"))
      reversed = Class.new(described_class)
      reversed.register("api/echo", answering("deep"))
      reversed.register("api", answering("shallow"))

      expect(backend.get("/api/echo/1")).to eq({ "matched" => "deep" })
      expect(backend.get("/api/other")).to eq({ "matched" => "shallow" })
      expect(reversed.new.get("/api/echo/1")).to eq({ "matched" => "deep" })
      expect(reversed.new.get("/api/other")).to eq({ "matched" => "shallow" })
    end

    it "matches prefixes on whole segments, not substrings" do
      backend_class.register("api/echo", echo_handler)

      expect { backend.get("/api/echoes/1") }.to raise_error(HttpResource::ApiError)
    end

    it "memoizes ONE handler instance per backend" do
      backend_class.register("api/echo", echo_handler)

      first = backend.get("/api/echo/1")
      second = backend.get("/api/echo/2")

      expect([first["calls"], second["calls"]]).to eq([1, 2])
      expect(backend_class.new.get("/api/echo/1")["calls"]).to eq(1)
    end

    it "builds the handler with THIS backend's store — seeded data is visible to it" do
      captured_store = nil
      capturing_handler = Class.new do
        define_method(:initialize) { |store| captured_store = store }
        define_method(:call) { |*, **| captured_store[:contacts].first }
      end
      backend_class.register("api/echo", capturing_handler)
      backend.seed(contacts: [{ email: "a@b.se" }])

      response = backend.get("/api/echo/1")

      expect(captured_store).to equal(backend.store)
      expect(response["email"]).to eq("a@b.se")
    end

    it "accepts and ignores the transport-only timeout kwargs on EVERY verb" do
      backend_class.register("api/echo", echo_handler)

      expect(backend.get("/api/echo/1", open_timeout: 1, read_timeout: 2)["verb"]).to eq("get")
      %i[post put patch].each do |verb|
        expect(backend.public_send(verb, "/api/echo", { a: 1 }, open_timeout: 1, read_timeout: 2)["verb"])
          .to eq(verb.to_s)
      end
      expect(backend.delete("/api/echo/1", open_timeout: 1, read_timeout: 2)["verb"]).to eq("delete")
    end

    it "returns the handler's response as a FRESH copy — mutation can't corrupt the store" do
      returning_record = Class.new do
        define_method(:initialize) { |store| @store = store }
        define_method(:call) { |*, **| @store[:contacts].first }
      end
      backend_class.register("api/contacts", returning_record)
      backend.seed(contacts: [{ email: "a@b.se" }])

      first = backend.get(%w[api contacts 1])
      first["email"] = "MUTATED"
      second = backend.get(%w[api contacts 1])

      expect(second["email"]).to eq("a@b.se")
      expect(second).not_to equal(first)
      expect(backend.store[:contacts].first["email"]).to eq("a@b.se")
    end

    it "normalizes a handler's symbol-keyed response to string keys (the contract's shape)" do
      sloppy = Class.new do
        define_method(:initialize) { |_store| nil }
        define_method(:call) { |*, **| { data: { id: 1 } } }
      end
      backend_class.register("api/sloppy", sloppy)

      expect(backend.get("/api/sloppy/1")).to eq({ "data" => { "id" => 1 } })
    end
  end

  describe "params normalization (transport parity)" do
    before { backend_class.register("api/echo", echo_handler) }

    it "converges symbol- and string-keyed params to the same server-side string pairs" do
      expect(backend.get("/api/echo/1", params: { limit: 4 })["params"]).to eq({ "limit" => "4" })
      expect(backend.get("/api/echo/1", params: { "limit" => "4" })["params"]).to eq({ "limit" => "4" })
    end

    it "converges params: {} to nil — an empty hash produces no query string on the wire" do
      expect(backend.get("/api/echo/1", params: {})["params"]).to be_nil
    end
  end

  describe "per-subclass registry" do
    it "isolates registrations between sibling subclasses (no leakage)" do
      other_class = Class.new(described_class)
      backend_class.register("api/mine", answering("mine"))
      other_class.register("api/theirs", answering("theirs"))

      expect(backend.get("/api/mine/1")).to eq({ "matched" => "mine" })
      expect { backend.get("/api/theirs/1") }.to raise_error(HttpResource::ApiError)
      expect { other_class.new.get("/api/mine/1") }.to raise_error(HttpResource::ApiError)
    end

    it "walks inheritance: a subclass sees its ancestors' handlers" do
      backend_class.register("api/parent", answering("parent"))
      child = Class.new(backend_class)

      expect(child.new.get("/api/parent/1")).to eq({ "matched" => "parent" })
    end

    it "does not serve a stale memoized handler after a nearer same-prefix registration" do
      backend_class.register("api/x", answering("parent"))
      child = Class.new(backend_class)
      instance = child.new

      expect(instance.get("/api/x/1")).to eq({ "matched" => "parent" }) # memoizes the parent handler
      child.register("api/x", answering("child"))
      expect(instance.get("/api/x/1")).to eq({ "matched" => "child" })
    end

    it "lets the NEAREST class win: a subclass match shadows a LONGER parent match" do
      backend_class.register("api/contacts/special", answering("parent-deep"))
      child = Class.new(backend_class)
      child.register("api/contacts", answering("child"))

      expect(child.new.get("/api/contacts/special/1")).to eq({ "matched" => "child" })
      expect(backend.get("/api/contacts/special/1")).to eq({ "matched" => "parent-deep" })
    end
  end

  describe "body handling (transport parity)" do
    before { backend_class.register("api/echo", echo_handler) }

    it "hands the handler a JSON payload in PARSED form — string keys, like a real server sees" do
      expect(backend.post("/api/echo", { data: { a: 1 } }))
        .to include("verb" => "post", "payload" => { "data" => { "a" => 1 } })
      expect(backend.put("/api/echo/1", { b: 2 })).to include("verb" => "put", "payload" => { "b" => 2 })
      expect(backend.patch("/api/echo/1", { c: 3 })).to include("verb" => "patch", "payload" => { "c" => 3 })
    end

    it "hands a form: body to the handler as decoded string pairs" do
      expect(backend.post("/api/echo", form: { grant: "x", n: 1 })["payload"])
        .to eq({ "grant" => "x", "n" => "1" })
    end

    it "folds a repeated form key last-wins, like a bare-key server-side parse" do
      expect(backend.post("/api/echo", form: { a: [1, 2], b: "x" })["payload"])
        .to eq({ "a" => "2", "b" => "x" })
    end

    %i[post put patch].each do |verb|
      it "#{verb} raises ArgumentError on BOTH a payload and form:, like the real Client" do
        expect { backend.public_send(verb, "/api/echo", { a: 1 }, form: { b: 2 }) }
          .to raise_error(ArgumentError, /both/)
      end
    end

    it "raises JSON::GeneratorError on an unserializable payload, like the real build_request" do
      expect { backend.post("/api/echo", { amount: Float::NAN }) }.to raise_error(JSON::GeneratorError)
    end

    it "delete and get carry no body" do
      expect(backend.delete("/api/echo/1")["payload"]).to be_nil
      expect(backend.get("/api/echo/1")["payload"]).to be_nil
    end
  end

  describe "path normalization (transport parity)" do
    before { backend_class.register("api/echo", echo_handler) }

    it "strips slashes and percent-decodes String path segments" do
      expect(backend.get("/api/echo/a%2Bb%40c.se/")["segments"]).to eq(["a+b@c.se"])
    end

    it "takes Array segments raw (pre-encoding) and stringifies non-strings" do
      expect(backend.get(["api", "echo", "a+b@c.se", 42])["segments"]).to eq(["a+b@c.se", "42"])
    end

    it "rejects a blank Array segment, like the real encoder" do
      expect { backend.get(["api", "echo", ""]) }.to raise_error(ArgumentError, /blank/)
      expect { backend.get(["api", "echo", nil]) }.to raise_error(ArgumentError, /blank/)
    end

    it "rejects a '.'/'..' dot-segment, like the real encoder" do
      expect { backend.get(["api", "echo", "."]) }.to raise_error(ArgumentError, /dot-segment/)
      expect { backend.get(["api", "echo", ".."]) }.to raise_error(ArgumentError, /dot-segment/)
    end

    it "raises URI::InvalidURIError on a malformed %-escape in a String path, like the real URI build" do
      expect { backend.get("/api/echo/%ZZ") }.to raise_error(URI::InvalidURIError)
    end

    it "raises URI::InvalidURIError on a URI-invalid raw character in a String path, like the real build" do
      expect { backend.get("/api/echo/a b") }.to raise_error(URI::InvalidURIError)
    end

    it "guards in production order: a bad path wins over a bad payload" do
      expect { backend.post(["api", ""], { amount: Float::NAN }) }
        .to raise_error(ArgumentError, /blank/)
    end

    it "guards the body BEFORE any injection fires (prod raises pre-network), preserving the injection" do
      backend.fail_next(status: 500)

      expect { backend.post(%w[api echo], { amount: Float::NAN }) }.to raise_error(JSON::GeneratorError)
      expect { backend.get("/api/echo/1") }.to raise_error(HttpResource::ServerError) # still queued
    end
  end

  describe "unregistered paths" do
    it "raises a loud 501 naming the verb and path — a ServerError, never Expected" do
      expect { backend.get(["api", "nope", 7]) }.to raise_error(HttpResource::ServerError) { |error|
        expect(error.status).to eq(501)
        expect(error.message).to eq("no simulation handler for GET /api/nope/7")
        expect(error).not_to be_a(HttpResource::Expected) # can never be soft-nil'd by a resource
      }
    end
  end

  describe "#fail_next" do
    before { backend_class.register("api/echo", echo_handler) }

    it "raises the mapped error class with a String body on the next call, then behaves normally" do
      backend.fail_next(status: 422, body: '{"errors":["bad"]}')

      expect { backend.post("/api/echo", { a: 1 }) }.to raise_error(HttpResource::ValidationError) { |error|
        expect(error.status).to eq(422)
        expect(error.body).to eq('{"errors":["bad"]}')
      }
      expect(backend.post("/api/echo", { a: 1 })["verb"]).to eq("post")
    end

    it "JSON-encodes a Hash body: — a real transport error always carries a String body" do
      backend.fail_next(status: 422, body: { errors: ["bad"] })

      expect { backend.get("/api/echo/1") }.to raise_error(HttpResource::ValidationError) { |error|
        expect(error.body).to eq('{"errors":["bad"]}')
      }
    end

    it "normalizes on: like a path, so a leading slash still matches" do
      backend.fail_next(status: 503, on: "/api/echo")

      expect { backend.get("/api/echo/1") }.to raise_error(HttpResource::ServerError)
    end

    it "skips a non-matching scoped injection and PRESERVES it (FIFO among matches)" do
      backend_class.register("api/contacts", echo_handler)
      backend.fail_next(status: 503, on: "contacts")
      backend.fail_next(status: 500)

      # /api/echo doesn't match the scoped injection -> the unscoped 500 fires.
      expect { backend.get("/api/echo/1") }.to raise_error(HttpResource::ServerError) { |error|
        expect(error.status).to eq(500)
      }
      # The scoped injection is still queued and fires on its path.
      expect { backend.get(["api", "contacts", 1]) }.to raise_error(HttpResource::ServerError) { |error|
        expect(error.status).to eq(503)
      }
      expect(backend.get(["api", "contacts", 1])["verb"]).to eq("get")
    end

    it "consumes multiple queued injections FIFO" do
      backend.fail_next(status: 500)
      backend.fail_next(status: 404)

      expect { backend.get("/api/echo/1") }.to raise_error(HttpResource::ServerError)
      expect { backend.get("/api/echo/1") }.to raise_error(HttpResource::NotFoundError)
      expect(backend.get("/api/echo/1")["verb"]).to eq("get")
    end

    it "fires even before registry lookup (an unregistered path can still fail-inject)" do
      backend.fail_next(status: 500)

      expect { backend.get("/api/unregistered") }.to raise_error(HttpResource::ServerError) { |error|
        expect(error.status).to eq(500) # the injection, not the 501
      }
    end
  end

  describe "#reset!" do
    it "clears the store, pending injections and memoized handlers" do
      backend_class.register("api/echo", echo_handler)
      backend.seed(contacts: [{ email: "a@b.se" }])
      expect(backend.get("/api/echo/1")["calls"]).to eq(1) # memoize a handler BEFORE the reset
      backend.fail_next(status: 500)
      backend.reset!

      expect(backend.store[:contacts]).to be_empty
      # No raise (injection gone) and a FRESH handler instance (count restarts,
      # proving @handlers was cleared — a stale instance would answer 2).
      expect(backend.get("/api/echo/1")["calls"]).to eq(1)
    end
  end
end
