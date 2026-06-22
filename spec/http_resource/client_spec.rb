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

  describe "form-encoded bodies (form:)" do
    it "POSTs application/x-www-form-urlencoded and parses the JSON reply (OAuth token)" do
      stub = stub_request(:post, "#{base_url}/oauth/token")
             .with(basic_auth: %w[u p],
                   headers: { "Content-Type" => "application/x-www-form-urlencoded",
                              "Accept" => "application/json" },
                   body: { grant_type: "client_credentials", scope: "a b" })
             .to_return(status: 200, body: { access_token: "tok" }.to_json)
      expect(client.post(%w[oauth token], form: { grant_type: "client_credentials", scope: "a b" }))
        .to eq("access_token" => "tok")
      expect(stub).to have_been_requested
    end

    it "URL-encodes keys/values (reserved chars), not JSON" do
      stub = stub_request(:post, "#{base_url}/oauth/token")
             .with(body: "grant_type=authorization_code&redirect_uri=https%3A%2F%2Fa.test%2Fcb")
             .to_return(status: 200, body: "{}")
      client.post(%w[oauth token],
                  form: { grant_type: "authorization_code", redirect_uri: "https://a.test/cb" })
      expect(stub).to have_been_requested
    end

    it "encodes an array form value as repeated keys" do
      stub = stub_request(:post, "#{base_url}/oauth/token").with(body: "scope=a&scope=b")
                                                           .to_return(status: 200, body: "{}")
      client.post(%w[oauth token], form: { scope: %w[a b] })
      expect(stub).to have_been_requested
    end

    it "surfaces a non-2xx form POST as a typed ApiError carrying the error payload (invalid_grant)" do
      stub_request(:post, "#{base_url}/oauth/token")
        .to_return(status: 400, body: { error: "invalid_grant" }.to_json)
      expect { client.post(%w[oauth token], form: { grant_type: "authorization_code", code: "bad" }) }
        .to raise_error(HttpResource::ClientError) do |e|
          expect(e.status).to eq(400)
          expect(JSON.parse(e.body)).to eq("error" => "invalid_grant")
        end
    end

    it "supports form bodies on PUT and PATCH too" do
      put = stub_request(:put, "#{base_url}/api/x")
            .with(headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: { a: "1" })
            .to_return(status: 200, body: "{}")
      patch = stub_request(:patch, "#{base_url}/api/x")
              .with(headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: { b: "2" })
              .to_return(status: 200, body: "{}")
      client.put(%w[api x], form: { a: 1 })
      client.patch(%w[api x], form: { b: 2 })
      expect(put).to have_been_requested
      expect(patch).to have_been_requested
    end

    it "PUT also takes a JSON body (the new verb mirrors post/patch)" do
      stub = stub_request(:put, "#{base_url}/api/x")
             .with(headers: { "Content-Type" => "application/json" }, body: { a: 1 }.to_json)
             .to_return(status: 200, body: "{}")
      client.put(%w[api x], { a: 1 })
      expect(stub).to have_been_requested
    end

    %i[post put patch].each do |verb|
      it "#{verb} raises ArgumentError (and makes NO request) when given BOTH a payload and form:" do
        expect { client.public_send(verb, %w[api x], { a: 1 }, form: { b: 2 }) }
          .to raise_error(ArgumentError, /both/)
      end
    end

    it "sends an empty form ({}) as an empty body, with the form Content-Type still set" do
      stub = stub_request(:post, "#{base_url}/oauth/token")
             .with(headers: { "Content-Type" => "application/x-www-form-urlencoded" }, body: "")
             .to_return(status: 200, body: "{}")
      client.post(%w[oauth token], form: {})
      expect(stub).to have_been_requested
    end

    it "encodes a non-ASCII form value as UTF-8 with space as '+' (form convention, not %20)" do
      stub = stub_request(:post, "#{base_url}/oauth/token").with(body: "name=%C3%85sa+%C3%96berg")
                                                           .to_return(status: 200, body: "{}")
      client.post(%w[oauth token], form: { name: "Åsa Öberg" })
      expect(stub).to have_been_requested
    end

    it "PUT with neither a payload nor form sends no body and no Content-Type" do
      stub = stub_request(:put, "#{base_url}/api/x")
             .with { |req| req.body.to_s.empty? && !req.headers.key?("Content-Type") }
             .to_return(status: 200, body: "{}")
      client.put(%w[api x])
      expect(stub).to have_been_requested
    end

    it "does NOT accept form: on the bodyless verbs get/delete (keeps the surface honest)" do
      expect { client.get(%w[api x], form: { a: 1 }) }.to raise_error(ArgumentError)
      expect { client.delete(%w[api x], form: { a: 1 }) }.to raise_error(ArgumentError)
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
