# RFC 0002: Initial closing schedule planning

- Status: accepted for initial planning only
- Maintainer decision: Will McLemore, 2026-09-08
- Specification target: optional initial schedule planner, version 1
- Discussion: issue #33 and proposal PR #34

## Decision and scope

The maintainer approved minute batches rather than sub-minute staggering,
nonconsecutive group membership, and a default shared deadline equal to the
latest member slot, with explicit override. This records that scoped decision
and permits its initial-planning implementation.

The separate direction that proxy adjustments do not change closing clocks is
not implemented here. Acceptance of this planning subset is not acceptance of
the entire flexible live scheduling transaction/coordinator proposal.

## Accepted rules

Given an explicit ordered list of unique unit IDs, opening time, first closing
time and positive integer N, zero-based position i receives first closing time
plus floor(i / N) minutes. The first closing time must follow opening. The
planner uses elapsed 60-second minutes and explicit-zone timestamps; no local
clock, current time or display-label arithmetic determines the result.

A group supplies a unique group ID and a nonempty list of known unit IDs. Each
unit belongs to at most one group. Consecutive display numbers and adjacency in
the ordered list are not required. The default group time is the latest of its
members' original assigned times. An explicit group time overrides that default
and must follow opening. All group members receive that resolved time.
Ungrouped units keep their assigned times; grouping does not compact the list.
Member-list and group-list order do not change the resulting schedule.

The output is a plan only. It accepts no existing bidding state and performs no
mutation, registration, live shortening, soft-close extension or group close.
Hosts must not apply it over an active auction as a substitute for the proposed
atomic scheduling coordinator. A planned group does not give RFC 0001 engines
linked soft-close capability.

## Validation and compatibility

Reject duplicate/empty IDs, unknown members, overlapping groups, invalid count,
unknown group properties, invalid timestamps, closes at/before opening, and
computed times outside the four-digit-year timestamp contract. Return no partial
plan. Count uses the existing interoperable integer bound (2**53 - 1).

No baseline command, event, version or pricing behavior changes. Existing gem
release metadata continues to describe the released baseline; this additive
helper requires a later package release before it is available to consumers.

Portable examples live in `conformance/initial-scheduling/`; the language-neutral
API is documented in `specification/initial-closing-schedule.md`. Reference tests
execute those examples against the helper, not a live coordinator.
