# frozen_string_literal: true

RSpec.describe HttpResource::Client do
  let(:base_url) { "https://api.example.org" }
  let(:client) { described_class.new(base_url:, auth: HttpResource::Auth.basic("u", "p")) }

  describe "configuration" do
    it "raises ConfigurationError on a blank base_url" do
      expect { described_class.new(base_url: "") }
        .to raise_error(HttpResource::ConfigurationError, /base_url/)
      expect { described_class.new(base_url: nil) }
        .to raise_error(HttpResource::ConfigurationError, /base_url/)
    end

    it "strips a trailing slash from base_url" do
      c = described_class.new(base_url: "#{base_url}/")
      stub = stub_request(:get, "#{base_url}/api/ping").to_return(status: 200, body: "{}")
      c.get(%w[api ping])
      expect(stub).to have_been_requested
    end

    it "defaults to no auth header when neither auth nor credentials are given" do
      c = described_class.new(base_url:)
      stub = stub_request(:get, "#{base_url}/api/ping")
             .with { |req| !req.headers.key?("Authorization") }
             .to_return(status: 200, body: "{}")
      c.get(%w[api ping])
      expect(stub).to have_been_requested
    end

    it "defaults to Basic auth when username/password are given (no explicit auth:)" do
      c = described_class.new(base_url:, username: "u", password: "p")
      stub = stub_request(:get, "#{base_url}/api/ping").with(basic_auth: %w[u p])
                                                       .to_return(status: 200, body: "{}")
      c.get(%w[api ping])
      expect(stub).to have_been_requested
    end
  end

  describe "verbs" do
    it "GETs with params encoded into the query string" do
      stub = stub_request(:get, "#{base_url}/api/contacts?limit=10&q=a%20b")
             .with(basic_auth: %w[u p], headers: { "Accept" => "application/json" })
             .to_return(status: 200, body: { ok: true }.to_json)
      expect(client.get(%w[api contacts], params: { q: "a b", limit: 10 })).to eq("ok" => true)
      expect(stub).to have_been_requested
    end

    it "POSTs a JSON body with Content-Type set" do
      stub = stub_request(:post, "#{base_url}/api/actions")
             .with(basic_auth: %w[u p],
                   headers: { "Content-Type" => "application/json" },
                   body: { a: 1 }.to_json)
             .to_return(status: 201, body: { id: 9 }.to_json)
      expect(client.post(%w[api actions], { a: 1 })).to eq("id" => 9)
      expect(stub).to have_been_requested
    end

    it "PATCHes and DELETEs" do
      stub_request(:patch, "#{base_url}/api/contacts/x").with(body: { n: 1 }.to_json)
                                                        .to_return(status: 200, body: "{}")
      stub_request(:delete, "#{base_url}/api/contacts/x").to_return(status: 204, body: "")
      expect(client.patch(%w[api contacts x], { n: 1 })).to eq({})
      expect(client.delete(%w[api contacts x])).to be_nil
    end

    it "sends a String path verbatim" do
      stub = stub_request(:get, "#{base_url}/api/ping").to_return(status: 200, body: "{}")
      client.get("/api/ping")
      expect(stub).to have_been_requested
    end

    it "returns the raw body string when the 2xx body is not JSON" do
      stub_request(:get, "#{base_url}/api/text").to_return(status: 200, body: "plain")
      expect(client.get(%w[api text])).to eq("plain")
    end
  end

  describe "status -> typed error" do
    {
      404 => HttpResource::NotFoundError,
      422 => HttpResource::ValidationError,
      401 => HttpResource::AuthError,
      403 => HttpResource::AuthError,
      302 => HttpResource::RedirectError,
      500 => HttpResource::ServerError,
      503 => HttpResource::ServerError
    }.each do |status, klass|
      it "raises #{klass} on a #{status}, carrying status + body" do
        stub_request(:get, "#{base_url}/api/x").to_return(status:, body: "details")
        expect { client.get(%w[api x]) }.to raise_error(klass) do |e|
          expect(e.status).to eq(status)
          expect(e.body).to eq("details")
        end
      end
    end

    it "classifies a 3xx as RedirectError — neither client nor server error" do
      stub_request(:get, "#{base_url}/api/x")
        .to_return(status: 302, headers: { "Location" => "https://elsewhere.test" })
      expect { client.get(%w[api x]) }.to raise_error(HttpResource::RedirectError) do |e|
        expect(e).not_to be_client_error
        expect(e).not_to be_server_error
      end
    end
  end

  describe "transport classification" do
    it "wraps a timeout as TimeoutError (a TransportError, nil status, unclassifiable)" do
      stub_request(:get, "#{base_url}/api/x").to_timeout
      expect { client.get(%w[api x]) }.to raise_error(HttpResource::TimeoutError) do |e|
        expect(e).to be_a(HttpResource::TransportError)
        expect(e.status).to be_nil
        expect(e).not_to be_client_error
        expect(e).not_to be_server_error
      end
    end

    it "wraps a connection failure as ConnectionError (a TransportError, nil status)" do
      stub_request(:get, "#{base_url}/api/x").to_raise(Errno::ECONNREFUSED)
      expect { client.get(%w[api x]) }.to raise_error(HttpResource::ConnectionError) do |e|
        expect(e).to be_a(HttpResource::TransportError)
        expect(e.status).to be_nil
      end
    end

    it "wraps an unexpected error as a bare TransportError" do
      stub_request(:get, "#{base_url}/api/x").to_raise(RuntimeError.new("weird"))
      expect { client.get(%w[api x]) }.to raise_error(HttpResource::TransportError)
    end
  end

  describe "build-outside-rescue (does NOT mask deterministic bugs)" do
    it "lets a JSON::GeneratorError (un-serializable payload) propagate, NOT a TransportError" do
      # No HTTP request is made — the body fails to serialize before the rescue.
      expect { client.post(%w[api x], { amount: Float::NAN }) }
        .to raise_error(JSON::GeneratorError)
    end

    it "lets a URI::InvalidURIError (bad String path) propagate, NOT a TransportError" do
      c = described_class.new(base_url: "https://api.example.org")
      expect { c.get("api/ foo\\bad") }.to raise_error(URI::InvalidURIError)
    end
  end

  describe "per-call timeout override" do
    before do
      stub_request(:get, "#{base_url}/api/x").to_return(status: 200, body: "{}")
    end

    it "forwards a per-call read_timeout to the underlying Net::HTTP" do
      expect_any_instance_of(Net::HTTP).to receive(:read_timeout=).with(2).and_call_original
      client.get(%w[api x], read_timeout: 2)
    end

    it "forwards a per-call open_timeout to the underlying Net::HTTP" do
      expect_any_instance_of(Net::HTTP).to receive(:open_timeout=).with(1).and_call_original
      client.get(%w[api x], open_timeout: 1)
    end

    it "applies the client default read_timeout (15) when no override is given" do
      expect_any_instance_of(Net::HTTP).to receive(:read_timeout=).with(15).and_call_original
      client.get(%w[api x])
    end

    it "applies the client default open_timeout (5) when no override is given" do
      expect_any_instance_of(Net::HTTP).to receive(:open_timeout=).with(5).and_call_original
      client.get(%w[api x])
    end
  end
end
