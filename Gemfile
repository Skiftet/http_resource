# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies: NONE (stdlib only) — see http_resource.gemspec.
gemspec

# Test + lint + release deps (not shipped with the gem).
group :development, :test do
  gem "rake", "~> 13.0" # `rake release` / `rake build` for the Release workflow
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.65"
  gem "webmock", "~> 3.23"
end
