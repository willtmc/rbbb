# RFC 0003: Fixed-membership shared closing clock

- Status: accepted for the clock component only
- Maintainer decision: Will McLemore, 2026-09-08
- Discussion: #33 and proposed flexible scheduling PR #34

## Scoped decision

Implement the approved shared quiet-period rule for arbitrary group members.
A qualifying new bid within the last X seconds keeps every member open until
at least bid time plus X seconds. Repeated qualifying bids restart that quiet
period. The current leader's own proxy increases and reductions never extend
time, even if the public standing changes (for example, crossing the reserve).
An outbid bidder raising an existing maximum is a qualifying bid, whether or not
it retakes the lead. Rejected bids never extend time.

The component consumes the existing pure engine's accepted decision records.
An accepted decision with a public `standing_bid_changed` event qualifies,
except the current leader adjusting their own maximum (`maximum_increased` or
`maximum_reduced` whose bidder is the resulting leader, with `leader_changed`
false). Any decision whose `standing_bid_changed` reports `leader_changed`
qualifies. This classification follows existing engine event meanings, not a
caller's boolean.

## Component boundary

This is one immutable clock for a fixed set of units, not a complete auction
coordinator. The host must serialize all affected decisions, validate unit and
schedule revisions, and commit unit state, the resulting clock, events and
receipts atomically. The helper does not claim those database/service guarantees.
Live regrouping, per-member state synchronization, group outcome commits,
receipt replay and external notification delivery remain separate work.

When using the component, the decision's unit engine must have its independent
extension disabled and its current closing time synchronized to the shared
clock. The decision record must retain that same deadline. Feeding decisions
with a different deadline is refused. The component never rewrites private bid
state or decomposes a promised group transaction into individual writes.

## Rules

A group has a nonempty stable ID, a nonempty duplicate-free set of unit IDs,
a shared closing time, a positive quiet period in seconds, a revision and the
last processed accepted decision time. Labels and membership order have no
scheduling meaning. Both trigger and duration equal the quiet period.

For a qualifying accepted new bid with time t, require t strictly before the
current deadline. At or inside the trigger boundary, the resulting deadline is
max(current deadline, t + quiet period). Every member reads this same deadline.
A changed deadline advances the clock revision exactly once. Accepted proxy
adjustments leave deadline and revision unchanged but advance the private last
processed time. Time regression is refused. No decision can revive an elapsed
clock. Rejections leave the entire clock unchanged.

Unknown members, stale expected revisions, unsupported accepted decision types,
malformed records and unsupported timestamp/count ranges are refused. Revisions
and seconds use the existing 2**53-1 integer bound; timestamps retain the existing
millisecond/four-digit-year contract. Overflow returns no new clock.

The baseline RFC 0001 engine and its independent extension behavior remain
unchanged. No linked-group service or release capability is advertised here.

## Amendments

- 2026-09-24 ([RFC 0004](0004-flexible-live-scheduling.md) decision): narrowed
  the non-extending proxy adjustment to the current leader's own changes. The
  original rule let an outbid bidder raise an existing maximum in the final
  seconds and retake the lead without extending the group, which defeats soft
  close. No release contained the original rule.
