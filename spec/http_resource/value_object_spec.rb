# frozen_string_literal: true

RSpec.describe HttpResource::ValueObject do
  let(:klass) do
    Data.define(:email, :name) { extend HttpResource::ValueObject }
  end

  it "returns nil for a nil payload (no ghost object)" do
    expect(klass.from(nil)).to be_nil
  end

  it "unwraps a top-level { data: {...} } envelope" do
    obj = klass.from("data" => { "email" => "a@b.se", "name" => "Anna" })
    expect(obj.email).to eq("a@b.se")
    expect(obj.name).to eq("Anna")
  end

  it "reads a flat (un-enveloped) payload too" do
    obj = klass.from("email" => "a@b.se", "name" => "Anna")
    expect(obj.email).to eq("a@b.se")
  end

  it "tolerates symbol keys" do
    obj = klass.from(email: "a@b.se", name: "Anna")
    expect(obj.email).to eq("a@b.se")
    expect(obj.name).to eq("Anna")
  end

  it "defaults missing keys to nil instead of raising" do
    obj = klass.from("email" => "a@b.se")
    expect(obj.name).to be_nil
  end

  it "ignores unknown keys in the payload" do
    obj = klass.from("email" => "a@b.se", "name" => "Anna", "extra" => "ignored")
    expect(obj.email).to eq("a@b.se")
  end

  it "uses a custom #build when the host defines one" do
    custom = Data.define(:slug) do
      extend HttpResource::ValueObject

      def self.build(data) = new(slug: data["slug"].to_s.upcase)
    end
    expect(custom.from("slug" => "news").slug).to eq("NEWS")
  end
end
