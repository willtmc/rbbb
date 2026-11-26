# Fixed-membership shared closing clock, version 1

Governing rules: [RFC 0003](../rfcs/0003-shared-closing-clock.md).

Construct a clock with `group_id`, `unit_ids`, `closes_at`, and positive integer
`quiet_period_seconds`. Initial revision is zero. Submit a real `Decision` using
`after_decision(unit_id:, decision:, expected_revision:)`. It returns a new
immutable clock; rejection returns the original clock. Original input is never
mutated. All members use `deadline_for(unit_id)` and `due?(at:)` against that
clock. A due clock permits a host to attempt an ordered group close; it does not
produce outcomes or close units by itself.

Accepted decision records must contain exactly one privileged transition of
type `maximum_accepted`, `maximum_increased` or `maximum_reduced`. Its closing
time must equal the clock's current deadline. A decision with a public
`standing_bid_changed` event qualifies to reset the quiet period, unless it is
the current leader adjusting their own maximum: a `maximum_increased` or
`maximum_reduced` whose `bidder_id` equals its `leader_id` while
`leader_changed` is false. A `leader_changed` decision always qualifies.
The record's authoritative time controls the arithmetic. A host must obtain
these records from the engine; untrusted event deserialization is not an API.

`public_view` contains only group ID, sorted unit IDs, deadline and revision.
`to_h` additionally contains the quiet period and private last accepted decision
time; it is a control-plane snapshot, not a public projection. Bid amounts,
bidder identities and private maxima are never copied into either clock view.
The clock does not persist receipts or replace a transactional host coordinator.
