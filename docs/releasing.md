# Release process

RBBB publishes the Ruby evaluation gem through GitHub Actions and RubyGems
trusted publishing. The workflow receives a short-lived, gem-scoped credential
through OpenID Connect; the repository must never store a RubyGems API key.

## One-time trusted-publisher setup

The maintainer configures both sides before the first registry release:

1. Create a protected GitHub environment named `release`. Limit deployments to
   version tags and require maintainer approval when the repository plan allows
   it.
2. Under the maintainer's RubyGems.org profile, create a pending trusted
   publisher with gem name `rbbb`, repository owner `willtmc`, repository name
   `rbbb`, workflow filename `release.yml`, and environment `release`.

After the first successful publication, RubyGems converts the pending publisher
into the gem's trusted publisher and adds the maintainer as an owner.

## Version release checklist

1. Confirm the target specification and conformance versions.
2. Run all conformance, unit, property, replay, and document checks on every
   supported Ruby version.
3. Review the diff for private data and public maximum-bid disclosure.
4. Update the changelog and version files in a pull request.
5. Require protected-branch CI to pass and merge normally.
6. Create and push an annotated, immutable `v<gem-version>` tag from the
   reviewed, GitHub-verified `main` merge commit. The tag must exactly match
   `RBBB::VERSION`.
7. Approve the `release` environment deployment. The pinned three-stage release
   workflow separates privileges across three jobs:
   - `verify` (`contents: read`): checks that the tag matches `RBBB::VERSION`,
     is reachable from `origin/main`, and is recorded in `CHANGELOG.md`, then
     reruns document validation, the test suite, `package:verify`, and a clean
     gem build.
   - `publish-rubygems` (`contents: read`, `id-token: write`, `release`
     environment): publishes the gem through RubyGems trusted publishing and
     uploads the exact published `.gem` artifact.
   - `github-release` (`contents: write`, `release` environment): attaches that
     exact `.gem` artifact and SHA-256 checksum to the matching GitHub release
     (marking non-stable builds as prereleases with the non-production warning).
8. Read back the RubyGems version, owners, metadata links, installed package,
   GitHub release, artifact checksum, and tag target.

## Evaluation artifact

The repository may build a prerelease gem for local review without publishing
it:

```sh
cd ruby/engine
bundle exec rake package:verify
gem build rbbb.gemspec
```

`package:verify` is the required preflight. It checks the exact file allowlist,
world-readable package inputs, prerelease and compatibility metadata, isolated
installation, and a bid decision from the installed artifact. A successful
local build is not a registry release.

Publishing `rbbb` for the first time requires explicit maintainer approval and
the pending trusted-publisher setup above. Do not fall back to a developer
workstation push or add a long-lived registry token when trusted publishing is
temporarily unavailable; fix the release path and retry the same immutable
version only if RubyGems confirms that version was not created.
