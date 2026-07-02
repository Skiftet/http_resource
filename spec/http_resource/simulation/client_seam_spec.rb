# frozen_string_literal: true

require "http_resource/simulation"

RSpec.describe "Client simulation seam" do
  let(:backend_class) { Class.new(HttpResource::Simulation::Backend) }

  let(:echo_handler) do
    Class.new do
      def initialize(store) = @store = store

      def call(verb, segments, payload:, params:)
        { "verb" => verb.to_s, "segments" => segments, "payload" => payload, "params" => params }
      end
    end
  end

  it "simulation: true routes the verbs to a backend — no URI build, no network, zero stubs" do
    backend_class.register("api/echo", echo_handler)
    chosen_backend = backend_class # local: visible inside the class body below
    client_class = Class.new(HttpResource::Client) do
      define_singleton_method(:simulation_backend_class) { chosen_backend }
    end
    Class.new(HttpResource::Client) # unrelated subclass; proves the hook is per-class
    client = client_class.new(base_url: "https://irrelevant.test", simulation: true)

    # WebMock's disable_net_connect! is active and NO stub is registered: any
    # real HTTP attempt would raise. Reaching the handler proves no network.
    expect(client.get(["api", "echo", 42], params: { limit: 1 }))
      .to include("verb" => "get", "segments" => ["42"], "params" => { "limit" => "1" })
    expect(client.post(%w[api echo], { a: 1 })).to include("verb" => "post", "payload" => { "a" => 1 })
    expect(client.put(%w[api echo x], form: { b: 2 }))
      .to include("verb" => "put", "payload" => { "b" => "2" })
    expect(client.patch(%w[api echo x], { c: 3 })).to include("verb" => "patch")
    expect(client.delete(%w[api echo x])["verb"]).to eq("delete")
  end

  it "rejects params: on a non-get through the private request seam (never silently dropped)" do
    client = HttpResource::Client.new(base_url: "https://x.test", simulation: backend_class.new)

    expect { client.send(:request, :post, %w[api x], body: { a: 1 }, params: { dry_run: 1 }) }
      .to raise_error(ArgumentError, /params: is only supported on get/)
  end

  it "simulation: true on the base Client uses Simulation::Backend itself" do
    client = HttpResource::Client.new(base_url: "https://x.test", simulation: true)

    expect(client.simulation).to be_an_instance_of(HttpResource::Simulation::Backend)
  end

  it "accepts an injected backend INSTANCE and exposes it via #simulation" do
    backend_class.register("api/echo", echo_handler)
    backend = backend_class.new
    backend.seed(contacts: [{ email: "a@b.se" }])
    client = HttpResource::Client.new(base_url: "https://x.test", simulation: backend)

    expect(client.simulation).to equal(backend)
    expect(client.simulation.store[:contacts].first["email"]).to eq("a@b.se")
    expect(client.get(%w[api echo 1])["verb"]).to eq("get")
  end

  it "#simulation is nil in real mode" do
    expect(HttpResource::Client.new(base_url: "https://x.test").simulation).to be_nil
  end

  it "still requires base_url in simulation mode" do
    expect { HttpResource::Client.new(base_url: "", simulation: true) }
      .to raise_error(HttpResource::ConfigurationError, /base_url/)
  end

  it "keeps the transport's deterministic-bug guards through the seam" do
    backend_class.register("api/echo", echo_handler)
    client = HttpResource::Client.new(base_url: "https://x.test", simulation: backend_class.new)

    expect { client.get(["api", "echo", ""]) }.to raise_error(ArgumentError, /blank/)
    expect { client.get(["api", "echo", ".."]) }.to raise_error(ArgumentError, /dot-segment/)
    expect { client.post(%w[api echo], { a: 1 }, form: { b: 2 }) }.to raise_error(ArgumentError, /both/)
    expect { client.post(%w[api echo], { amount: Float::NAN }) }.to raise_error(JSON::GeneratorError)
  end

  it "fail_next reaches the caller as the typed error through the client" do
    backend = backend_class.new
    client = HttpResource::Client.new(base_url: "https://x.test", simulation: backend)
    client.simulation.fail_next(status: 422)

    expect { client.post(%w[api anything], { a: 1 }) }.to raise_error(HttpResource::ValidationError)
  end

  it "is NOT loaded by a plain require (lazy: only the simulation: kwarg pulls it in)" do
    lib = File.expand_path("../../../lib", __dir__)
    # exit 0 = correct; exit 2 = eagerly loaded; exit 1 = subprocess crashed.
    script = 'require "http_resource"; exit(defined?(HttpResource::Simulation) ? 2 : 0)'

    system(RbConfig.ruby, "-I", lib, "-e", script)
    expect(Process.last_status.exitstatus).to eq(0)
  end

  it "IS loaded by the simulation: kwarg (the positive half of lazy loading)" do
    lib = File.expand_path("../../../lib", __dir__)
    script = 'require "http_resource"; ' \
             'c = HttpResource::Client.new(base_url: "https://x.test", simulation: true); ' \
             "exit(c.simulation.instance_of?(HttpResource::Simulation::Backend) ? 0 : 2)"

    system(RbConfig.ruby, "-I", lib, "-e", script)
    expect(Process.last_status.exitstatus).to eq(0)
  end
end
