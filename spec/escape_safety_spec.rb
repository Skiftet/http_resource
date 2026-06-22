# frozen_string_literal: true

require "uri"

# The load-bearing guarantee: an UNTRUSTED path segment passed in an Array can
# NEVER escape the protocol. It must land as exactly ONE percent-encoded path
# component on the CONFIGURED host — it cannot introduce a second path segment,
# change the host/scheme, add a query or fragment, or inject CRLF.
#
# These specs capture the EXACT URI Net::HTTP was asked to fetch (before any
# WebMock normalisation) and assert structural invariants on it directly.
RSpec.describe "escape safety" do
  let(:base_url) { "https://api.example.org" }
  let(:client) { HttpResource::Client.new(base_url:, auth: HttpResource::Auth.basic("u", "p")) }

  # Capture the real URI handed to Net::HTTP for the request.
  def captured_uri_for(segment)
    captured = nil
    stub_request(:get, %r{\Ahttps://api\.example\.org/}).to_return do |request|
      captured = request.uri
      { status: 200, body: "{}" }
    end
    client.get(["api", "contacts", segment])
    captured
  end

  ADVERSARIAL = {
    "path traversal" => "../../etc/passwd",
    "path + query + fragment" => "a/b?c#d",
    "absolute url" => "https://evil.com/x",
    "CRLF header injection" => "x\r\nHost: evil.com",
    "pre-encoded traversal" => "%2e%2e%2f",
    "space" => "a b",
    "unicode" => "Ångström—über",
    "semicolon param" => ";semi",
    "userinfo at-sign" => "@host",
    "triple dot (NOT a dot-segment)" => "..."
  }.freeze

  ADVERSARIAL.each do |name, segment|
    context "with an adversarial segment (#{name}): #{segment.inspect}" do
      let(:uri) { captured_uri_for(segment) }

      it "keeps the request on the CONFIGURED host + scheme + port" do
        expect(uri.scheme).to eq("https")
        expect(uri.host).to eq("api.example.org")
        expect(uri.port).to eq(443)
      end

      it "introduces NO query and NO fragment" do
        expect(uri.query).to be_nil
        expect(uri.fragment).to be_nil
      end

      it "introduces NO userinfo (cannot smuggle an @host authority)" do
        expect(uri.userinfo).to be_nil
      end

      it "lands the segment as exactly ONE extra path component under /api/contacts" do
        # Split the *encoded* path: the segment must not have added a slash.
        encoded_parts = uri.path.sub(%r{\A/}, "").split("/")
        expect(encoded_parts.length).to eq(3)
        expect(encoded_parts[0, 2]).to eq(%w[api contacts])

        # And it must decode back to exactly the original input — proving it is
        # the WHOLE segment, faithfully round-tripped, with nothing escaping.
        # url_encode emits %XX for everything reserved (and never a bare "+"),
        # so a strict percent-decode recovers the original byte-for-byte.
        decoded = encoded_parts[2].gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).to_i(16).chr }
                                  .force_encoding("UTF-8")
        expect(decoded).to eq(segment)
      end

      it "contains NO raw CR or LF in the request line (no header injection)" do
        expect(uri.to_s).not_to include("\r")
        expect(uri.to_s).not_to include("\n")
      end

      it "does not let a '/' in the segment create a real path separator" do
        # The only '/' separators are the two we authored before the segment.
        expect(uri.path.count("/")).to eq(3)
      end

      it "leaves NO bare dot-segment a server could normalise to climb the path" do
        # A lone "." / ".." would survive url_encode (dots are unreserved) and a
        # server's remove_dot_segments could use it to traverse — they must be %2E.
        segments = uri.path.split("/")
        expect(segments).not_to include(".")
        expect(segments).not_to include("..")
      end
    end
  end

  it "encodes a space as %20 (NOT + the way CGI.escape would), so it stays a path component" do
    uri = captured_uri_for("a b")
    expect(uri.path).to end_with("/a%20b")
    expect(uri.path).not_to include("+")
  end

  # The same load-bearing guarantee for FORM bodies: an untrusted key or value
  # can NEVER inject a header, a second field, or CRLF — it is percent-encoded.
  it "percent-encodes CRLF + reserved chars in a form body (no header/field injection)" do
    captured = nil
    stub_request(:post, "#{base_url}/oauth/token").to_return do |request|
      captured = request.body
      { status: 200, body: "{}" }
    end
    client.post(%w[oauth token], form: { a: "x\r\nX-Injected: 1", "k\r\n" => "v" })
    expect(captured).to include("%0D%0A") # CRLF survives only as its encoding
    expect(captured).not_to include("\r")
    expect(captured).not_to include("\n")
    expect(captured).not_to include("X-Injected:") # never escaped into a raw header/field
  end

  it "sends a trusted String path verbatim (documented escape hatch)" do
    stub = stub_request(:get, "#{base_url}/api/raw/path").to_return(status: 200, body: "{}")
    client.get("/api/raw/path")
    expect(stub).to have_been_requested
  end

  it "rejects a blank/nil Array segment (would otherwise collapse into '//')" do
    expect { client.get(["api", "", "contacts"]) }.to raise_error(ArgumentError, /blank/)
    expect { client.get(["api", "contacts", nil]) }.to raise_error(ArgumentError, /blank/)
  end

  it "rejects a '.' or '..' dot-segment id (no encoding survives strict normalisation)" do
    expect { client.get(["api", "contacts", "."]) }.to raise_error(ArgumentError, /dot-segment/)
    expect { client.get(["api", "contacts", ".."]) }.to raise_error(ArgumentError, /dot-segment/)
  end
end
