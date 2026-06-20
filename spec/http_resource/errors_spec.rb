# frozen_string_literal: true

RSpec.describe HttpResource::ApiError do
  describe ".for_status" do
    {
      404 => HttpResource::NotFoundError,
      422 => HttpResource::ValidationError,
      401 => HttpResource::AuthError,
      403 => HttpResource::AuthError,
      400 => HttpResource::ClientError,
      418 => HttpResource::ClientError,
      499 => HttpResource::ClientError,
      300 => HttpResource::RedirectError,
      302 => HttpResource::RedirectError,
      399 => HttpResource::RedirectError,
      500 => HttpResource::ServerError,
      503 => HttpResource::ServerError,
      599 => HttpResource::ServerError,
      200 => HttpResource::ApiError,
      600 => HttpResource::ApiError
    }.each do |status, klass|
      it "maps #{status} -> #{klass}" do
        error = described_class.for_status("boom", status:, body: "b")
        expect(error).to be_a(klass)
        expect(error.status).to eq(status)
        expect(error.body).to eq("b")
      end
    end
  end

  describe "status predicates" do
    it "client_error? is status-guarded (Integer, 400..499)" do
      expect(described_class.new(status: 404)).to be_client_error
      expect(described_class.new(status: 500)).not_to be_client_error
      expect(described_class.new(status: nil)).not_to be_client_error
    end

    it "server_error? is status-guarded (Integer, 500..599)" do
      expect(described_class.new(status: 503)).to be_server_error
      expect(described_class.new(status: 404)).not_to be_server_error
      expect(described_class.new(status: nil)).not_to be_server_error
    end

    it "not_found? is true only for 404" do
      expect(described_class.new(status: 404)).to be_not_found
      expect(described_class.new(status: 410)).not_to be_not_found
    end
  end

  describe "the Expected marker" do
    it "is included ONLY by NotFoundError (the one swallow-to-nil case)" do
      expect(HttpResource::NotFoundError.ancestors).to include(HttpResource::Expected)
      [
        HttpResource::ValidationError, HttpResource::AuthError, HttpResource::ClientError,
        HttpResource::RedirectError, HttpResource::ServerError, HttpResource::TransportError,
        HttpResource::TimeoutError, HttpResource::ConnectionError, HttpResource::ApiError
      ].each do |klass|
        expect(klass.ancestors).not_to include(HttpResource::Expected)
      end
    end
  end

  describe "the hierarchy (rescue-by-parent)" do
    it "nests the specific 4xx under ClientError, and timeout/connection under TransportError" do
      expect(HttpResource::NotFoundError.new).to be_a(HttpResource::ClientError)
      expect(HttpResource::ValidationError.new).to be_a(HttpResource::ClientError)
      expect(HttpResource::AuthError.new).to be_a(HttpResource::ClientError)
      expect(HttpResource::ClientError.new).to be_a(HttpResource::ApiError)
      expect(HttpResource::TimeoutError.new).to be_a(HttpResource::TransportError)
      expect(HttpResource::ConnectionError.new).to be_a(HttpResource::TransportError)
      expect(HttpResource::TransportError.new).to be_a(HttpResource::ApiError)
      expect(HttpResource::ServerError.new).to be_a(HttpResource::ApiError)
    end

    it "roots everything at HttpResource::Error, with ConfigurationError a sibling of ApiError" do
      expect(HttpResource::ApiError.new).to be_a(HttpResource::Error)
      expect(HttpResource::ConfigurationError.new).to be_a(HttpResource::Error)
      expect(HttpResource::ConfigurationError.new).not_to be_a(HttpResource::ApiError)
    end
  end
end
