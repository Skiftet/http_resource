# frozen_string_literal: true

require "http_resource/simulation"

RSpec.describe HttpResource::Simulation::Store do
  subject(:store) { described_class.new }

  describe "#[] (collection-agnostic access)" do
    it "auto-vivifies ANY collection name as an empty Array" do
      expect(store[:contacts]).to eq([])
      expect(store[:anything_else]).to eq([])
    end

    it "returns the LIVE collection reference (handlers mutate in place)" do
      store[:contacts] << { "id" => 1 }
      expect(store[:contacts]).to eq([{ "id" => 1 }])
    end

    it "unifies string and symbol collection names" do
      store["contacts"] << { "id" => 1 }
      expect(store[:contacts]).to eq([{ "id" => 1 }])
    end
  end

  describe "#next_id" do
    it "runs an independent sequence per collection" do
      expect(store.next_id(:contacts)).to eq(1)
      expect(store.next_id(:contacts)).to eq(2)
      expect(store.next_id(:payments)).to eq(1)
    end
  end

  describe "#seed" do
    it "appends records under ANY collection names, assigning ids when absent" do
      store.seed(contacts: [{ email: "a@b.se" }, { email: "c@d.se" }], invoices: [{ total: 100 }])

      expect(store[:contacts].map { _1["id"] }).to eq([1, 2])
      expect(store[:invoices]).to eq([{ "total" => 100, "id" => 1 }])
    end

    it "accepts string collection names" do
      store.seed("invoices" => [{ total: 100 }])
      expect(store[:invoices].first["total"]).to eq(100)
    end

    it "keeps an explicitly seeded Integer id and sequences future ids past it" do
      store.seed(contacts: [{ id: 5, email: "a@b.se" }, { email: "b@c.se" }])

      expect(store[:contacts].map { _1["id"] }).to eq([5, 6])
      expect(store.next_id(:contacts)).to eq(7)
    end

    it "normalizes ALL keys (deeply) to strings" do
      store.seed(contacts: [{ email: "a@b.se", "subscriptions" => [{ type: "Email", slug: "news" }] }])

      expect(store[:contacts].first).to eq(
        "email" => "a@b.se",
        "subscriptions" => [{ "type" => "Email", "slug" => "news" }],
        "id" => 1
      )
    end

    it "raises on a duplicate explicit id within a collection (explicit vs explicit)" do
      store.seed(contacts: [{ id: 5 }])
      expect { store.seed(contacts: [{ id: 5 }]) }
        .to raise_error(ArgumentError, /duplicate id 5 in :contacts/)
    end

    it "raises when an explicit id equals an already-auto-assigned id" do
      store.seed(contacts: [{ email: "a@b.se" }]) # auto id 1
      expect { store.seed(contacts: [{ id: 1 }]) }.to raise_error(ArgumentError, /duplicate id 1/)
    end

    it "compares duplicate ids as strings — \"5\" and 5 are the same id to a handler" do
      store.seed(contacts: [{ id: "5" }])
      expect { store.seed(contacts: [{ id: 5 }]) }.to raise_error(ArgumentError, /duplicate/)
    end

    it "advances the sequence past an integer-LIKE String id so it can't be aliased later" do
      store.seed(contacts: [{ id: "2" }, {}, {}])

      expect(store[:contacts].map { _1["id"] }).to eq(["2", 3, 4])
    end

    it "never rewinds the sequence when a lower explicit id follows a higher one" do
      store.seed(contacts: [{ id: 5 }, { id: 2 }])
      expect(store.next_id(:contacts)).to eq(6)
    end

    it "rejects a non-Array records value loudly (a lone Hash is a caller bug)" do
      expect { store.seed(contacts: { email: "a@b.se" }) }
        .to raise_error(ArgumentError, /records for :contacts must be an Array of Hashes, got Hash/)
    end

    it "allows the same explicit id in DIFFERENT collections" do
      store.seed(contacts: [{ id: 5 }], payments: [{ id: 5 }])
      expect([store[:contacts], store[:payments]].map { _1.first["id"] }).to eq([5, 5])
    end

    it "keeps a String id (UUID-style) without advancing the Integer sequence" do
      store.seed(contacts: [{ id: "abc-123" }, { email: "x@y.se" }])

      expect(store[:contacts].map { _1["id"] }).to eq(["abc-123", 1])
    end
  end

  describe "#reset!" do
    it "clears every collection and restarts the id sequences" do
      store.seed(contacts: [{ email: "a@b.se" }])
      store.reset!

      expect(store[:contacts]).to be_empty
      expect(store.next_id(:contacts)).to eq(1)
    end

    it "keeps previously-obtained collection references LIVE across a reset" do
      reference = store[:contacts]
      store.seed(contacts: [{ email: "a@b.se" }])
      store.reset!

      expect(store[:contacts]).to equal(reference)
    end
  end

  describe "#deep_stringify" do
    it "is public — handlers JSON-shape records they build from payloads" do
      expect(store.deep_stringify({ a: [{ b: 1 }], "c" => 2 })).to eq("a" => [{ "b" => 1 }], "c" => 2)
    end
  end
end
