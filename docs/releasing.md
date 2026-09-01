# Release process

No artifact is released from a developer workstation automatically. Until the
first release workflow is reviewed, maintainers use this checklist:

1. Confirm the target specification and conformance versions.
2. Run all conformance, unit, property, replay, and document checks on every
   supported Ruby version.
3. Review the diff for private data and public maximum-bid disclosure.
4. Update the changelog and version files in a pull request.
5. Require protected-branch CI to pass and merge normally.
6. Create a signed, immutable version tag and GitHub release from `main`.
7. Publish packages with maintainer MFA and verify package contents and
   checksums from the public registry.
8. Read back the GitHub release, package version, and documentation links.

Publishing automation must use trusted GitHub environments or registry trusted
publishing rather than long-lived repository secrets whenever the registry
supports it.

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

Publishing `rbbb` for the first time requires explicit maintainer approval,
control of the registry namespace, MFA, and read-back verification. The
preferred long-term path is a protected GitHub `release` environment with
RubyGems trusted publishing; do not add a long-lived registry token to the
repository.
