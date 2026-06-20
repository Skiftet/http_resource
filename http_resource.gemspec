# frozen_string_literal: true

require_relative "lib/http_resource/version"

Gem::Specification.new do |spec|
  spec.name = "http_resource"
  spec.version = HttpResource::VERSION
  spec.authors = ["Skiftet"]
  spec.email = ["joel.e.svensson@skiftet.org"]

  spec.summary = "A tiny, zero-dependency framework for typed REST-resource clients on Net::HTTP."
  spec.description = "HttpResource gives you a Net::HTTP transport with a typed error " \
                     "hierarchy (NotFoundError, ValidationError, AuthError, " \
                     "ServerError, TimeoutError…), Rails-style bang/non-bang " \
                     "resources, pluggable auth strategies (Basic/Bearer/Header), " \
                     "per-call timeouts, and escape-safe URL building so untrusted " \
                     "path segments can never escape the protocol. Bring a base_url " \
                     "and an auth strategy; build clients and resources on top. " \
                     "Zero runtime dependencies (stdlib only)."
  spec.homepage = "https://github.com/Skiftet/http_resource"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/README.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # Runtime: stdlib only (net/http, json, uri, erb, openssl) — NO dependencies,
  # so adding the gem pulls nothing extra into a consumer's bundle.
end
