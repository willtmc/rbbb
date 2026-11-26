# Fixed bid ladder contract

- Normative authority: [RFC 0005: Fixed bid ladder with arbitrary maximum authority](../rfcs/0005-fixed-bid-ladder.md)
- Accepted by maintainer: 2026-10-23
- Specification: `0.2.0-draft` (incompatible with `0.1.0-draft`)
- Related contract: [Core specification contract](contract.md)

## Summary

RFC 0005 supersedes RFC 0001's short-increment pricing and raw-maximum tie
rules. The normative specification lives in
[RFC 0005](../rfcs/0005-fixed-bid-ladder.md) and is integrated into the core
boundaries in [contract.md](contract.md). Key contract boundaries:

- **Fixed published ladder:** every executed bid must fall on a published rung
  derived from the immutable opening amount and configured tier breakpoints and
  steps. There are no cut bids, including at the interoperable money ceiling.
- **Arbitrary entered maxima:** bidders may submit any otherwise-valid maximum.
  The engine retains the exact entered authorization, but only its highest
  executable rung `E(M)` participates in competition, reserve satisfaction,
  executed floors, and tie priority. Unused remainder has no competitive effect.
- **Priority and competition:** positions rank by `E(M)`, then authoritative
  acceptance order of that executable maximum. Edits within the same rung
  preserve priority. With competition, standing price is
  `min(leader E(M), next rung above runner-up E(M))`, subject to opening,
  reserve pressure, and binding executed floors.
- **Reserves, reductions, and corrections:** an off-ladder confidential reserve
  requires the first rung at or above the reserve; reductions cannot cross
  executed floors; operator voids replay the same ladder and priority rules
  from retained authorization history.
- **Private bidder notice:** a successful odd maximum or reduction emits a
  private, nonblocking `maximum_not_fully_executable` notice retained in the
  privileged command event and shown only to the submitting bidder or
  authorized operator.
- **Compatibility:** `0.2.0-draft` is incompatible with `0.1.0-draft`. Keep 0.1
  snapshots pinned to the 0.1 baseline; do not restore them into a 0.2 engine.

Refer to [RFC 0005](../rfcs/0005-fixed-bid-ladder.md) for the complete
normative text, examples, and validation requirements.
