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
