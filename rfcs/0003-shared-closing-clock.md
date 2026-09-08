# RFC 0003: Fixed-membership shared closing clock

- Status: accepted for the clock component only
- Maintainer decision: Will McLemore, 2026-09-08
- Discussion: #33 and proposed flexible scheduling PR #34

## Scoped decision

Implement the approved shared quiet-period rule for arbitrary group members.
A qualifying new bid within the last X seconds keeps every member open until
at least bid time plus X seconds. Repeated qualifying bids restart that quiet
period. Existing proxy-authority increases and reductions never extend time,
even if the public standing changes. Rejected bids never extend time.

The component consumes the existing pure engine's accepted decision records:
`maximum_accepted` together with `standing_bid_changed` qualifies; existing
proxy adjustments (`maximum_increased` or `maximum_reduced`) do not. This
classification follows existing engine event meanings, not a caller's boolean.

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
