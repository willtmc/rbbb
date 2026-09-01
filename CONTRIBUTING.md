# Contributing to R Triple B

RBBB needs both software expertise and auction-domain expertise. You do not
need to write Ruby to make a meaningful contribution.

## Good first contributions

- Describe an ambiguous auction situation as a synthetic scenario.
- Improve terminology that would confuse an auctioneer or bidder.
- Review a proposed rule for operational consequences.
- Add a conforming implementation in another language.
- Improve tests, documentation, accessibility, security, or observability.

## Before opening a change

Use a GitHub issue for bugs and bounded documentation fixes. Use an RFC for a
new rule or any change to normative behavior. Security reports must follow
[SECURITY.md](SECURITY.md), not the public issue tracker.

For behavior work:

1. State the policy question in plain language.
2. Describe the competing reasonable outcomes.
3. Add synthetic conformance scenarios, including boundary cases.
4. Update the language-neutral specification.
5. Update the reference implementation only after the intended behavior is
   reviewable in the specification and scenarios.

## Provenance and privacy

Contributions must be yours to license. Do not submit proprietary source code,
private documentation, production payloads, customer data, bidder identities,
payment details, or copied vendor behavior. Real operational experience should
be generalized into synthetic examples with invented IDs and amounts.

By contributing, you certify that you have the right to submit the work and
that the contribution is licensed under the repository's MIT License. The
project does not require copyright assignment or a separate contributor
license agreement.

## Development

The Ruby reference engine currently supports Ruby 3.2 and newer.

```sh
cd ruby/engine
bundle install
bundle exec rake
```

Validate repository documents from the repository root:

```sh
ruby scripts/validate_documents.rb
```

## Pull requests

- Use a focused branch and a Conventional Commit title.
- Explain the policy or defect, the chosen behavior, and how it was tested.
- Link the governing RFC for normative changes.
- Keep private maxima and other non-public facts out of public events,
  examples, logs, and rejection messages.
- Expect maintainers to request conformance cases before accepting behavior.

All contributors must follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
