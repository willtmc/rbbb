# Security policy

## Supported versions

RBBB has not made a production-ready release. No version is currently supported
for live bidding.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
vulnerability reporting feature on this repository's **Security** tab.

Include the affected component, reproduction steps, expected impact, and any
suggested mitigation. Do not include real bidder, auction, credential, or
payment data. Maintainers will acknowledge a report as soon as practical and
coordinate disclosure after a fix is available.

## Security model

The project's core trust boundaries include deterministic command ordering,
idempotency, authorization at the service boundary, immutable audit history,
transactional state changes, and prevention of private maximum-bid disclosure.
Designs that weaken those properties require explicit security review.
