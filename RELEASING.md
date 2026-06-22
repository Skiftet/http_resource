# Releasing http_resource

Publishing is automated via GitHub Actions + RubyGems **Trusted Publishing**
(OIDC). No API key or secret is stored anywhere — RubyGems verifies that the
release came from this repo's `.github/workflows/release.yml` workflow.

## One-time setup on RubyGems.org (maintainer, once)

http_resource is not on RubyGems yet, so register a **pending** trusted
publisher *before* the first release:

1. Sign in to https://rubygems.org, then open
   **Register a new pending publisher**:
   https://rubygems.org/profile/oidc/pending_trusted_publishers/new
2. Fill in exactly:
   - **RubyGem name:** `http_resource`
   - **Repository owner:** `Skiftet`
   - **Repository name:** `http_resource`
   - **Workflow filename:** `release.yml`
   - **Environment:** `release`
3. Save. After the first successful publish it auto-converts into a normal
   trusted publisher for the gem.

Also create the GitHub Environment so releases can be gated:
**Settings → Environments → New environment → `release`** (optionally add a
required reviewer for a manual approval step before each push).

## Cutting a release

1. Bump the version in `lib/http_resource/version.rb`.
2. Commit to `main` (update the README if needed).
3. **Actions → Release → Run workflow** (or `gh workflow run release.yml`).

The workflow runs the test suite, then `release-gem`: it builds the gem,
creates and pushes the `v<version>` git tag, generates a build-provenance
attestation, and pushes to RubyGems.org via OIDC. Re-running for a version that
is already published (or already tagged) fails safely.

## Consuming the gem

Once published, consumers drop the local path source and use:

```ruby
gem "http_resource"
```

Until then, the public repo can be used directly:

```ruby
gem "http_resource", git: "https://github.com/Skiftet/http_resource.git"
```
