# HttpResource

A tiny, **zero-dependency** Ruby framework for building typed REST-resource
clients on top of `Net::HTTP`.

You bring a `base_url` and an auth strategy; HttpResource gives you a transport
with a **typed error hierarchy**, Rails-style **bang/non-bang resources**,
**pluggable auth**, **per-call timeouts**, and **escape-safe URL building** so
untrusted path segments can never escape the protocol.

It is the generic core extracted from Skiftet's `mejla_api_client`: a small set
of proven patterns you would otherwise hand-roll (and get subtly wrong) in every
service-to-service client.

## Why

Most hand-rolled HTTP clients get three things wrong:

1. **They mask deterministic bugs as retryable failures.** A bad URL or an
   un-serializable payload gets caught by a broad `rescue` and turned into a
   "transport error", so a background worker retries it forever. HttpResource
   builds the request *outside* the network rescue, so those propagate.
2. **They flatten every failure into one exception.** A 404, a 422 validation
   rejection, an auth failure and a 5xx all need different handling. HttpResource
   maps each to a distinct, rescue-by-parent error class.
3. **They interpolate untrusted ids straight into URLs.** HttpResource encodes
   each array path segment as a single RFC-3986 path component — see
   [Escape safety](#escape-safety).

## Install

```ruby
# Gemfile
gem "http_resource"
```

```ruby
require "http_resource"
```

Requires Ruby >= 3.2. No runtime dependencies.

## Usage

### Build a client

```ruby
client = HttpResource::Client.new(
  base_url: "https://api.example.org",
  auth: HttpResource::Auth.bearer(ENV.fetch("API_TOKEN")),
  open_timeout: 5,   # optional, default 5
  read_timeout: 15   # optional, default 15
)

client.get(["api", "contacts", id])          # GET, id escaped as ONE path segment
client.post(["api", "actions"], { foo: 1 })  # POST a JSON body
client.put(["api", "contacts", id], { name: "Anna" })
client.patch(["api", "contacts", email], { name: "Anna" })
client.delete(["api", "contacts", id])
```

A `String` path is sent verbatim (`client.get("/api/ping")`); an `Array` path
has each segment percent-encoded (see [Escape safety](#escape-safety)).

Reads return parsed JSON (a `Hash`/`Array`, or `nil` on an empty body). Every
call raises an `HttpResource::ApiError` subclass on a non-2xx response or a
transport failure.

### Form-encoded bodies (OAuth)

`post`/`put`/`patch` take a `form:` keyword to send an
`application/x-www-form-urlencoded` body instead of JSON — for the form-encoded
endpoints OAuth consumers hit (RFC 6749 token, RFC 7662 introspection, …):

```ruby
token = client.post(["oauth", "token"], form: {
  grant_type: "client_credentials",
  scope: "read write"
})
token["access_token"]   # a 2xx still returns parsed JSON
```

The response side is identical to a JSON call — parsed JSON on a 2xx, a typed
`ApiError` on a non-2xx — so an OAuth failure is just a rescue-able error whose
`#body` carries the payload:

```ruby
begin
  client.post(["oauth", "token"], form: { grant_type: "authorization_code", code: bad })
rescue HttpResource::ClientError => e
  e.status                    # => 400
  JSON.parse(e.body)["error"] # => "invalid_grant"
end
```

Pass **either** a JSON `payload` **or** `form:`, never both (it raises
`ArgumentError`). Form keys/values are percent-encoded, so untrusted input can't
inject a header or an extra field.

### A process-wide default client

```ruby
HttpResource.configure do |c|
  c.base_url = ENV.fetch("API_URL")
  c.auth = HttpResource::Auth.basic(ENV.fetch("API_USER"), ENV.fetch("API_PASS"))
end

HttpResource.client.get(["api", "ping"])
```

`HttpResource.build_client(base_url: ..., auth: ...)` builds an independent
client when you talk to more than one host.

### Pluggable auth

An auth strategy is any object responding to `#apply(request)`. Three are shipped:

```ruby
HttpResource::Auth.basic("user", "pass")   # Authorization: Basic <base64>
HttpResource::Auth.bearer("token")         # Authorization: Bearer token
HttpResource::Auth.header("X-Api-Key", k)  # X-Api-Key: k
```

Passing `username:`/`password:` (and no `auth:`) defaults to Basic. Bring your
own strategy for anything else (HMAC signing, refreshing tokens, …).

### Resources: the bang/non-bang pattern

Subclass `HttpResource::Resource` to map an endpoint to typed verbs. Pair a
non-bang method (returns `nil` on an expected 404 miss) with a bang method
(raises on any failure):

```ruby
Contact = Data.define(:email, :name) do
  extend HttpResource::ValueObject   # tolerant .from(payload)
end

class Contacts < HttpResource::Resource
  def find(id)  = soft { find!(id) }   # nil on 404, raises on anything else

  def find!(id)
    data = @client.get(["api", "contacts", id])
    data && Contact.from(data)         # empty 2xx -> nil, never a ghost object
  end
end

contacts = Contacts.new(client)
contacts.find("missing")  # => nil   (404 swallowed)
contacts.find!("missing") # => raises HttpResource::NotFoundError
```

`soft { ... }` swallows **only** an `Expected` failure (a 404) to `nil`.
Everything else — including a 422 validation rejection on a write — raises even
from the non-bang form, so a sync job surfaces and retries the failure rather
than silently dropping a write.

`ValueObject#from` returns `nil` for a `nil` payload, unwraps a top-level
`{ "data" => {...} }` envelope, tolerates string or symbol keys, and defaults
missing keys to `nil`. Guarding `data && Contact.from(data)` means an empty 2xx
yields `nil`, not a ghost value object.

## Error hierarchy

Every failure is an `HttpResource::ApiError` carrying `#status` (an `Integer`, or
`nil` for transport failures) and `#body`. `ApiError.for_status` maps the HTTP
status to the most specific class, so you can rescue broadly or narrowly:

| Class | Status | `client_error?` | `server_error?` | `Expected` (→ nil) | Meaning |
|---|---|---|---|---|---|
| `ApiError` | any / other | by status | by status | no | base for all of the below |
| `ClientError` | 400–499 | yes | no | no | caller's request won't succeed on retry — drop |
| `NotFoundError` | 404 | yes | no | **yes** | resource missing; the only swallow-to-nil case |
| `ValidationError` | 422 | yes | no | no | request rejected; a write must surface, not drop |
| `AuthError` | 401, 403 | yes | no | no | bad/missing credentials — usually a config bug |
| `RedirectError` | 300–399 | no | no | no | unfollowed redirect — usually a wrong base_url |
| `ServerError` | 500–599 | no | yes | no | server failed a valid request — retryable |
| `TransportError` | nil | no | no | no | network failure before/while talking — retryable |
| `TimeoutError` | nil | no | no | no | connect/read exceeded the budget (a TransportError) |
| `ConnectionError` | nil | no | no | no | refused/reset/DNS/TLS (a TransportError) |

Because the tree nests, a worker can branch on intent:

```ruby
begin
  client.post(["api", "actions"], payload)
rescue HttpResource::ClientError       # 4xx — drop, don't retry
  drop!
rescue HttpResource::ServerError,      # 5xx + transport — retry
       HttpResource::TransportError
  retry_later!
end
```

`ConfigurationError` (a sibling of `ApiError` under `Error`) is raised eagerly
for a blank `base_url` — never on the network path.

## Timeouts

The client carries an `open_timeout` (default 5s) and `read_timeout` (default
15s). Override either for a single call — e.g. a short read on a synchronous
page render that must not stall:

```ruby
client.get(["api", "contacts", id], read_timeout: 2)
```

A connect or read that exceeds the budget raises `TimeoutError` (status `nil`).

## Escape safety

> **Path segments passed in an `Array` carry untrusted input** (ids, emails,
> tokens). HttpResource builds URLs so that input can **never** escape the
> protocol.

In `build_uri`, every `Array` segment is encoded with **`ERB::Util.url_encode`**
(RFC-3986 path-component encoding) before being joined with `/`. That encodes
`/`, `?`, `#`, `:`, `@`, `;`, CR/LF and every other reserved character — and a
space becomes `%20`, not `+` (which is why `CGI.escape` is *not* used: it
mis-encodes space and is for form bodies, not path components). Query params go
through `URI.encode_www_form`.

Two inputs **cannot** be safely encoded and are **rejected** with an
`ArgumentError` instead: a **blank/`nil`** segment (which would collapse into
`//`) and a bare **`.`** or **`..`** dot-segment. No percent-encoding survives a
strict normaliser (`%2E` decodes back to `.` per RFC 3986 §6.2.2.2, then
`remove_dot_segments` traverses), and no legitimate id is a dot-segment — so a
`.`/`..` id is an error, never a traversal.

The result: an adversarial segment fed to `client.get(["api", "contacts", seg])`
always lands as **one** percent-encoded path component on the **configured**
host (or is rejected). None of the following can break out:

| Adversarial segment | Cannot do |
|---|---|
| `../../etc/passwd` | introduce extra path segments / traverse (the `/` are encoded) |
| bare `.` / `..` | climb the path — **rejected** (no encoding survives normalisation) |
| `a/b?c#d` | add a path segment, query, or fragment |
| `https://evil.com/x` | change scheme or host |
| `x\r\nHost: evil.com` | inject CRLF / smuggle a header |
| `%2e%2e%2f` | sneak a pre-encoded `../` through |
| `a b`, `;semi`, `@host`, unicode | alter structure or authority |

A **`String`** path is the trusted escape hatch and is sent **verbatim** — so
**never interpolate untrusted input into a `String` path**; pass an `Array` and
let the framework encode it. The guarantee is covered by a dedicated,
adversarial spec (`spec/escape_safety_spec.rb`).

## Changelog

### 0.2.0

- Add a `form:` keyword to `post`/`put`/`patch` for `application/x-www-form-urlencoded`
  bodies (OAuth token/introspection and other form-encoded endpoints). Responses
  stay resty: parsed JSON on a 2xx, a typed `ApiError` (with `#body`) on a non-2xx.
- Add a first-class `put` verb (JSON or `form:` body).
- Passing both a JSON `payload` and `form:` raises `ArgumentError`; the bodyless
  verbs (`get`/`delete`) reject `form:`.

### 0.1.0

- Initial release: Net::HTTP transport, typed `ApiError` hierarchy, bang/non-bang
  resources, pluggable auth, per-call timeouts, escape-safe URL building.

## Development

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE) © Skiftet.
