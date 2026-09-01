# RBBB agent instructions

These rules apply to automated contributors working in this repository.

## Product boundary

- RBBB is an independent, open-source auction bidding engine.
- The standard is language-neutral. Ruby is the reference implementation, not
  a requirement for compatible implementations.
- Do not describe the initials as an acronym or assign them an official
  expansion.
- Do not claim production readiness before the maintainers explicitly declare
  it.

## Clean-room provenance

- Do not copy code, fixtures, payloads, identifiers, screenshots, private
  documentation, or non-public data from Gavel, Auction Method, or any other
  proprietary system.
- Contributions based on operational experience must be reduced to synthetic,
  non-identifying scenarios.
- If provenance is unclear, stop and ask before adding the material.

## Normative behavior

- Do not invent auction semantics in implementation code.
- A change to command behavior, event meaning, state transitions, ordering,
  pricing, ties, reserves, extensions, or operator overrides requires an
  accepted RFC and conformance scenarios.
- Keep normative requirements in `specification/` and observable examples in
  `conformance/`. The Ruby implementation must follow both.
- Determinism, idempotency, auditability, and non-disclosure of private maximum
  bids are trust boundaries, not optional features.

## Engineering workflow

- Use a feature branch and pull request; never push directly to `main`.
- Use Conventional Commits.
- Keep diffs narrow and add tests for behavior changes.
- Never commit secrets or real bidder, payment, or auction data.
- Keep commits, pull requests, CI, merge, release, and deployment as distinct
  completion states.
- Avoid destructive Git operations and preserve unrecognized work.
