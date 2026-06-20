# frozen_string_literal: true

RSpec.describe "HttpResource module-level config" do
  let(:base_url) { "https://api.example.org" }

  it "builds a default client from configuration and memoizes it" do
    HttpResource.configure do |c|
      c.base_url = base_url
      c.auth = HttpResource::Auth.basic("u", "p")
    end

    stub = stub_request(:get, "#{base_url}/api/ping").with(basic_auth: %w[u p])
                                                     .to_return(status: 200, body: { ok: true }.to_json)

    expect(HttpResource.client.get(%w[api ping])).to eq("ok" => true)
    expect(HttpResource.client).to be(HttpResource.client) # memoized
    expect(stub).to have_been_requested
  end

  it "carries configured timeouts onto the built client" do
    HttpResource.configure do |c|
      c.base_url = base_url
      c.read_timeout = 3
    end
    stub_request(:get, "#{base_url}/api/x").to_return(status: 200, body: "{}")
    expect_any_instance_of(Net::HTTP).to receive(:read_timeout=).with(3).and_call_original
    HttpResource.client.get(%w[api x])
  end

  it "build_client makes an independent client with per-call overrides" do
    HttpResource.configure { |c| c.base_url = base_url }
    other = HttpResource.build_client(base_url: "https://other.example.org",
                                      auth: HttpResource::Auth.bearer("t"))
    stub = stub_request(:get, "https://other.example.org/api/x")
           .with(headers: { "Authorization" => "Bearer t" })
           .to_return(status: 200, body: "{}")
    other.get(%w[api x])
    expect(stub).to have_been_requested
  end

  it "defaults configuration timeouts to the client defaults" do
    config = HttpResource::Configuration.new
    expect(config.open_timeout).to eq(HttpResource::Client::DEFAULT_OPEN_TIMEOUT)
    expect(config.read_timeout).to eq(HttpResource::Client::DEFAULT_READ_TIMEOUT)
  end
end
