# frozen_string_literal: true

RSpec.describe HttpResource::Resource do
  let(:base_url) { "https://api.example.org" }
  let(:client) { HttpResource::Client.new(base_url:, auth: HttpResource::Auth.basic("u", "p")) }
  let(:contacts) { SpecSupport::Contacts.new(client) }

  describe "bang/non-bang on a 404" do
    before do
      stub_request(:get, "#{base_url}/api/contacts/gone")
        .with(basic_auth: %w[u p])
        .to_return(status: 404, body: { error: "not found" }.to_json)
    end

    it "find returns nil (expected miss swallowed to nil)" do
      expect(contacts.find("gone")).to be_nil
    end

    it "find! raises NotFoundError, carrying the status + body" do
      expect { contacts.find!("gone") }.to raise_error(HttpResource::NotFoundError) do |e|
        expect(e.status).to eq(404)
        expect(e).to be_not_found
        expect(e).to be_client_error
        expect(e.body).to include("not found")
      end
    end
  end

  describe "a write rejection (422) is UNEXPECTED — raises from BOTH forms" do
    before do
      stub_request(:post, "#{base_url}/api/contacts")
        .to_return(status: 422, body: { error: "invalid" }.to_json)
    end

    it "create AND create! both raise ValidationError (the write must not be swallowed)" do
      [-> { contacts.create(foo: "bar") }, -> { contacts.create!(foo: "bar") }].each do |call|
        expect(&call).to raise_error(HttpResource::ValidationError) do |e|
          expect(e.status).to eq(422)
          expect(e).to be_client_error
        end
      end
    end
  end

  describe "non-bang still raises on the UNEXPECTED" do
    it "raises AuthError (401) even from the non-bang find" do
      stub_request(:get, "#{base_url}/api/contacts/x").to_return(status: 401, body: "")
      expect { contacts.find("x") }
        .to raise_error(HttpResource::AuthError) { |e| expect(e.status).to eq(401) }
    end

    it "raises ServerError (503) even from the non-bang find" do
      stub_request(:get, "#{base_url}/api/contacts/x").to_return(status: 503, body: "down")
      expect { contacts.find("x") }
        .to raise_error(HttpResource::ServerError) { |e| expect(e).to be_server_error }
    end

    it "raises TimeoutError even from the non-bang find" do
      stub_request(:get, "#{base_url}/api/contacts/x").to_timeout
      expect { contacts.find("x") }.to raise_error(HttpResource::TimeoutError)
    end
  end

  describe "ghost guard — empty 2xx -> nil, never a value object" do
    it "find returns nil when a 2xx read has an empty body" do
      stub_request(:get, "#{base_url}/api/contacts/x").to_return(status: 204, body: "")
      expect(contacts.find("x")).to be_nil
      expect(contacts.find!("x")).to be_nil
    end

    it "builds the value object from a populated 2xx body" do
      stub_request(:get, "#{base_url}/api/contacts/x")
        .to_return(status: 200, body: { data: { email: "a@b.se", name: "Anna" } }.to_json)
      contact = contacts.find("x")
      expect(contact).to be_a(SpecSupport::Contact)
      expect(contact.email).to eq("a@b.se")
      expect(contact.name).to eq("Anna")
    end
  end
end
