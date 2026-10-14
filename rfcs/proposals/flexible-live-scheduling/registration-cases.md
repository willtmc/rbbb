# Synthetic registration acceptance cases

Status: **draft review cases; not executable conformance fixtures or passed tests**.
These cases depend on acceptance of [registration-contract.md](registration-contract.md).
All identifiers, bidders, configurations and times below are invented.

## Shared fixture and exact oracle

Auction `auction-synthetic`, tenant `tenant-synthetic`, authenticated operator
`operator-synthetic` with current `register` and `schedule` permissions.
Clock: `2031-04-05T12:00:00Z`; policy minimum shortening lead: 60 seconds.
Scheduling revision: 7. Existing standalone `unit-old` closes at
`2031-04-05T13:00:00Z`, version 3, with an accepted synthetic bidder position.
Capture its full configuration/state/closing set as `before_old`.

New intent `registration-one` creates `unit-new`, expected revision 7, reason
`Synthetic inventory arrival`, with this complete baseline configuration:

```json
{
  "currency": "USD",
  "opening_minor_units": 100,
  "reserve_minor_units": 500,
  "increments": [{"from_minor_units": 0, "amount_minor_units": 25}],
  "opens_at": "2031-04-05T11:00:00Z",
  "closes_at": "2031-04-05T13:30:00Z",
  "extension": {"trigger_window_seconds": 60, "duration_seconds": 120}
}
```

The success oracle is the full baseline empty state generated from that
configuration (not a partial-field match), one new standalone set with the exact
configuration deadline/extension, revision 8, and `before_old` unchanged.
The record oracle is exactly the contract's privileged creation at index 0 and
public scheduling delta at index 1, with one shared commit identity/time and new
unit version 0. One retained receipt and one private decision are added. Each
case resets the fixture unless explicitly describing continuation.

## Cases

| ID | Action | Required result |
| --- | --- | --- |
| REG-01 | Submit the shared intent while `unit-old` already has bids. | Exact success oracle; no inherited bids, fabricated bid events or manual-change notices. |
| REG-02 | Submit with future opening `12:10`, closing `13:30`. | Empty unit registered; baseline bidding rejects before opening; no exposure before schedule installation. |
| REG-03 | After REG-01 retry the identical normalized intent, same principal/key, after `14:00`. | Original receipt/time/commit returned; no fresh clock allocation, configuration, state, domain record or outbox entry. |
| REG-04 | After REG-01 reuse its key with a different reserve, reason or unit ID. | `command_id_reused`; original receipt/configuration/state unchanged; no receipt overwrite. |
| REG-05 | After REG-01 request its receipt as another principal, then as the original principal without current `register` permission. | `not_authorized`, with no original receipt, configuration, reserve or operator reason disclosed. |
| REG-06 | Attempt existing `unit-old` under a fresh key and matching revision; repeat with a terminal/catalog-removed unit. | Retained `unit_id_conflict`; byte-for-byte domain configuration/state/topology unchanged; decision bookkeeping only. |
| REG-07 | Stale revision plus duplicate unit and elapsed deadline. | Retained `stale_revision`, matching defined precedence. Retry after revision changes still returns original rejection. |
| REG-08 | Closing equals ordered time, or is earlier; separate configuration closes at/before opening. | Ordered `invalid_schedule` for elapsed deadline; invalid baseline configuration fails pre-admission with no durable decision/receipt. |
| REG-09 | Add caller `operator_id`, `effective_at`, state, version, group ID or unknown field; duplicate JSON keys or invalid UTF-8. | Pre-admission failure; no clock, sequence, receipt, state or outbox change. |
| REG-10 | Seal auction then submit new registration ID; retry an already retained accepted registration with authorization. | New ID retains `auction_sealed`; old ID returns original receipt without reopening. |
| REG-11 | Register then attach `unit-new` to an existing group using guarded membership command and complete current version vector. | Two separate commits; attachment advances affected unit versions once and revision once, preserving all accepted bids. Failed attachment leaves only the committed standalone registration; host visibility/admission stays withheld if group attachment was promised. |
| REG-12 | Two independent processes register the same new unit under different keys at revision 7. | Exactly one success/revision 8; loser retains `stale_revision`. Fresh-ID retry at revision 8 retains `unit_id_conflict`; never two creations. |
| REG-13 | Independent registration and edit race with expected revision 7; separately race registration and bid on `unit-old`. | Edit race has exactly one revision-precondition winner. Bid race produces an order equivalent to serial execution with no lost bids; registration does not overwrite the existing state. |
| REG-14 | Bid on `unit-new` races registration; independently reopen host after successful registration and bid. | Bid ordered before registration cannot accept an unknown unit; after registration can accept only with host admission. Reopen loads durable new configuration; later bid never reconstructs an empty unit. |
| REG-15 | Fail/SIGKILL immediately before commit; retry in a new process. | No registration/configuration/topology/receipt/domain/outbox survives rollback; retry creates exactly one complete success. |
| REG-16 | SIGKILL after commit before response; retry in a new process. | Entire success survives; original receipt replay; no second creation, revision or outbox identity. |
| REG-17 | SIGKILL after publishing the full batch but before outbox acknowledgment; restart delivery. | Same commit/index identities redelivered; consumer applies once; registration mutation is not rerun. |
| REG-18 | Replay exact full batch into matching before-state; then test missing creation, missing delta, reversed order, changed empty state/configuration, occupied ID or revision gap. | Full valid replay matches exact success oracle including registry. Every invalid/partial batch rejects atomically with unchanged projection/cursor. |
| REG-19 | Deliver public projection to authorized reader; attempt private projection without audit authority. | Public record contains no reserve, configuration, positions, operator/reason or privileged digest. Private access denied; unpublished inventory is filtered under host policy; gaps require consistent resync. |
| REG-20 | Safe-integer revision ceiling; exact byte/depth limits and plus-one; encoded batch limit and plus-one under immutable smaller profile. | Ceiling retains `version_exhausted`; admission overflow has no receipt; ordered batch overflow retains `resource_limit_exceeded`. Exact valid boundaries succeed; no splitting/partial registration. |
| REG-21 | Seal and archive, restore complete registry/state/receipts/outbox, retry accepted and rejected registrations. | Original receipts and redelivery identities survive; sealed restoration rejects new mutation IDs. Missing registry/deduplication history never permits resumed mutation. |

## Evidence needed after acceptance

Turn these rows into executable fixtures with complete before/after state,
configuration registry, record and receipt assertions. Concurrency cases require
independent database sessions/processes, crash cases real process termination,
and admission/publication cases a trusted host adapter rather than submitted
permission booleans. Compare public and privileged projections independently.
Passing document checks or existing FLS tests is not registration execution.
