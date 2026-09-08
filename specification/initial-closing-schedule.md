# Initial closing schedule planner, version 1

Governing decision: [RFC 0002](../rfcs/0002-initial-closing-schedules.md).
This optional helper computes a plan. It does not enable linked bidding groups.

Inputs:

- `unit_ids`: nonempty ordered array of unique, nonempty string identities.
  Displayed lot numbers are host metadata and are not parsed by this API.
- `opens_at`, `first_closes_at`: explicit-zone RFC 3339 times with at most
  millisecond precision. The first close must be strictly after opening.
- `lots_per_minute`: integer in 1..2**53-1. Each consecutive batch of this many
  units gets one deadline, exactly 60 elapsed seconds after the previous batch.
- `groups`: array of objects with exactly `group_id`, `unit_ids`, and optional
  `closes_at`. Group IDs are unique nonempty strings. Members are a nonempty
  duplicate-free subset of the input unit IDs with no overlap between groups.
  An override must be strictly after opening; omitting it selects the latest
  original member deadline.

Output contains `version: 1`, `scope: initial_schedule_plan_only`, original
`initial_closes_at` and resolved `unit_closes_at` maps, plus resolved `groups`.
Groups and their members are sorted by identity; unit maps follow input order.
Timestamps use the baseline canonical UTC format. All times must fit the
four-digit-year timestamp format after UTC normalization and arithmetic.
Invalid input raises an error without returning a partial plan or mutating input.

The output deliberately contains no accepted bids, events or mutations. An
initial override may be earlier than a member's original slot; this helper has
no existing auction state and cannot authorize shortening a live auction.
