# Request for comments process

Current pricing: [fixed bid ladder, odd maxima and no cut bids](0005-fixed-bid-ladder.md) (0.2.0-draft).

An RFC is required for any new or changed normative auction behavior, public
contract, compatibility guarantee, or governance model.

## Accepted RFCs

| RFC | Title | Status | Accepted | Scope |
| --- | --- | --- | --- | --- |
| [0001](0001-timed-online-proxy-bidding.md) | Timed online proxy bidding baseline | Accepted | 2026-09-01 | Core timed online proxy bidding (`0.2.0-draft`; pricing and tie rules superseded by RFC 0005) |
| [0002](0002-initial-closing-schedules.md) | Initial closing schedule planning | Accepted (initial planning only) | 2026-09-08 | Minute batches, nonconsecutive group planning, and explicit initial overrides (unreleased) |
| [0003](0003-shared-closing-clock.md) | Fixed-membership shared closing clock | Accepted (clock component only) | 2026-09-08 | Shared quiet-period clock component for fixed groups; amended by RFC 0004 proxy-adjustment rule (unreleased) |
| [0004](0004-flexible-live-scheduling.md) | Flexible live scheduling and closing groups | Accepted (reference implementation complete, unreleased) | 2026-09-24 | Mutable closing groups, registration, linked extensions, atomic close, and snapshot-first recovery (implemented in `#47`; deployment certification separate) |
| [0005](0005-fixed-bid-ladder.md) | Fixed bid ladder with arbitrary maximum authority | Accepted | 2026-10-23 | Fixed published ladder execution, odd maxima, no cut bids, and private bidder notices (`0.2.0-draft`, implemented in `#52`) |

## Process

1. Open an issue describing the policy question before writing a large RFC.
2. Copy `0000-template.md` and use a temporary descriptive filename.
3. Include synthetic conformance scenarios that make the decision observable.
4. Open a pull request and invite domain and implementation review.
5. A maintainer records the decision and assigns the permanent RFC number.
6. Accepted behavior lands in the specification, conformance suite, and
   reference implementation together.

An RFC may be proposed, accepted, rejected, withdrawn, or superseded. Merging a
proposed document does not make it normative unless its status says accepted.

## Proposals under review

None.

## Evaluation questions

- Can an auctioneer explain the behavior in plain language?
- Is the result deterministic for the same ordered inputs?
- Are ordering and serialization boundaries explicit?
- Does the design preserve private bidding facts?
- Can another language implement it from the public contract alone?
- Are failure, retry, and audit behavior testable?
- Is configuration finite and composable rather than arbitrary code?

## Accepted scoped additions

- [RFC 0002: Initial closing schedule planning](0002-initial-closing-schedules.md)
  defines minute batches and nonconsecutive group planning. It does not accept
  the separate live scheduling coordinator or change baseline bidding semantics.

- [RFC 0003: Fixed-membership shared closing clock](0003-shared-closing-clock.md)
  accepts the clock component only, not the full live scheduling coordinator.
  Amended by RFC 0004 (proxy-adjustment rule).

- [RFC 0004: Flexible live scheduling and closing groups](0004-flexible-live-scheduling.md)
  accepts the live regrouping/rescheduling contract, including a minimum
  shortening lead and leader-change extensions. The bounded reference
  coordinator and its durable host and snapshot-recovery examples are
  implemented in source (`#47`, unreleased; see
  [docs/live-scheduling-implementation.md](../docs/live-scheduling-implementation.md));
  deployment certification and capability advertisement remain separate.

- [RFC 0005: Fixed bid ladder with arbitrary maximum authority](0005-fixed-bid-ladder.md)
  replaces RFC 0001's short-increment pricing and raw-maximum tie rules with
  fixed published ladder execution and private bidder notices (`#52`,
  `0.2.0-draft`, unreleased).
