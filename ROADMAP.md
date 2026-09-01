# Roadmap

The roadmap describes intent, not a release promise.

## Phase 0: foundations

- Establish governance, security, contribution, and clean-room rules.
- Define the specification, RFC, and conformance formats.
- Agree on core terminology and trust boundaries.
- Record the first normative decisions through RFCs.

## Phase 1: timed online proxy bidding

- Specify command ordering, increments, maximum bids, ties, reserves, opening,
  closing, and extensions.
- Build a deterministic pure-Ruby engine against the conformance suite.
- Define stable command, event, state, and rejection schemas.
- Publish an embeddable Ruby gem for evaluation.

## Phase 2: reference service

- Build an API-only Ruby service with PostgreSQL as the authority.
- Add idempotent commands, transactional projections, subscriptions, audit
  queries, authentication boundaries, metrics, and incident tooling.
- Run replay, property, load, failure, and security tests.

## Phase 3: controlled production proof

- Shadow a production auction system without writing bids.
- Compare every decision and investigate every divergence.
- Pilot a narrowly controlled auction with one authoritative bidding engine.
- Publish operational findings without private or proprietary data.

## Later RFCs

Quantity, choice, linked soft-close groups, multi-parcel bidding, additional
auctioneer overrides, and other formats remain out of scope until their
semantics are specified and tested.

An optional rule that realigns a proxy-clipped short increment to the regular
increment grid is explicitly deferred. The v0.1 baseline permits short
increments and calculates the next required amount from the resulting standing
amount.
