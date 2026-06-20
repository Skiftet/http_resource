# frozen_string_literal: true

RSpec.describe HttpResource::Auth do
  let(:base_url) { "https://api.example.org" }

  def client(auth)
    HttpResource::Client.new(base_url:, auth:)
  end

  describe "Basic" do
    it "sets the Authorization: Basic header" do
      stub = stub_request(:get, "#{base_url}/api/ping")
             .with(basic_auth: %w[user pass])
             .to_return(status: 200, body: "{}")
      client(described_class.basic("user", "pass")).get(%w[api ping])
      expect(stub).to have_been_requested
    end
  end

  describe "Bearer" do
    it "sets the Authorization: Bearer header" do
      stub = stub_request(:get, "#{base_url}/api/ping")
             .with(headers: { "Authorization" => "Bearer secret-token" })
             .to_return(status: 200, body: "{}")
      client(described_class.bearer("secret-token")).get(%w[api ping])
      expect(stub).to have_been_requested
    end
  end

  describe "Header" do
    it "sets an arbitrary custom header" do
      stub = stub_request(:get, "#{base_url}/api/ping")
             .with(headers: { "X-Api-Key" => "abc123" })
             .to_return(status: 200, body: "{}")
      client(described_class.header("X-Api-Key", "abc123")).get(%w[api ping])
      expect(stub).to have_been_requested
    end
  end

  describe "a custom strategy" do
    it "accepts any object responding to #apply(request)" do
      strategy = Object.new
      def strategy.apply(request) = request["X-Signed"] = "yes"
      stub = stub_request(:get, "#{base_url}/api/ping")
             .with(headers: { "X-Signed" => "yes" })
             .to_return(status: 200, body: "{}")
      client(strategy).get(%w[api ping])
      expect(stub).to have_been_requested
    end
  end
end
