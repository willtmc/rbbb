# Behavioral vector format and execution boundary

[`behavior-vectors.jsonl`](behavior-vectors.jsonl) contains **29 invented vectors,
47 steps**, covering the 18 original review cases plus FLS-21 and FLS-22, with branches for equal timestamps,
elapsed versus terminal units, immediate versus future deadlines, incomplete
versus duplicate membership, and committed/rolled-back/rejected retries.

Each JSONL line is one independent case. No real auction records were used.

## Inputs and exact expectations

- `scheduling_policy` is trusted per-auction configuration
  (`minimum_shortening_lead_seconds`, 180 in every vector). It is fixed before
  the auction accepts scheduling commands and never comes from a submission.
- `unit_setup` supplies complete configurations and actual baseline command
  sequences. Empty new units have empty command sequences, not fabricated bids.
  The independent engine reconstructs every starting unit exactly.
- `initial_state` specifies complete unit snapshots, closing sets, and scheduling
  revision. Existing topology is a fixture starting condition, not a claim of
  reconstructed historical operator commands.
- `steps[].action` supplies the operation, trusted test clock/principal/permission
  context, and any injected crash. Operator actions distinguish their untrusted
  `submitted_intent` from the resulting trusted `command`. The adapter must not
  accept clock, principal, or commit identity from a production caller.
- `trusted_commit_id` controls the test service's identity source, so exact
  receipts are comparable across implementations without normalizing away a
  duplicate-commit bug. A rejected/rolled-back operation does not allocate a
  committed identity.
- `steps[].expected` gives the **entire resulting state**, ordered new record
  batch, rejection reason, and whether a durable receipt exists. A retry's
  `replayed_step` requires the exact original receipt; its `new_records` is
  empty. Returning an old receipt does not republish its records.

A `host_display_order` action is a host-only control case: it issues no engine
command. The new-unit case starts with a registered empty unit and exercises
attachment without inheriting bids; registration transaction/fault coverage is
an additional reference-service gate. Transport-invalid input has no durable
domain receipt. Fault-before-commit leaves state and receipts untouched;
fault-after-commit/before-response leaves the committed state and receipt intact.

Record ordering and scheduling-delta replay are defined in the
[service contract](service-contract.md). Baseline unit records retain their
native exact event bodies under `{unit_id, event}`. A complete public scheduling
delta coordinates peer updates without inventing bids. Audit and notification
records are separate projections and do not advance unit versions twice.

## What currently executes

`test/flexible_scheduling_vectors_test.rb` checks:

- all 20 review case IDs are covered and every vector is explicitly unverified;
- every vector declares a schema-valid trusted `scheduling_policy`, and every
  accepted shortening lands at or after `effective_at` plus its minimum lead;
- every initial snapshot is reproducible from independently authored baseline commands;
- every expected unit snapshot is valid, with coherent complete membership/deadlines;
- closed command/event/submission shapes and preservation of private bidding
  state across manual changes;
- exact baseline bid/close subrecords against the existing independent engine;
- unchanged domain state on rejection, rollback, and receipt replay;
- 4,096-member schema acceptance and boundary-plus-one rejection.

Run with `cd ruby/engine && bundle exec rake`.

**These are fixture-integrity and baseline checks, not coordinator conformance.**
There is no scheduling coordinator or database fault harness in this change.
An implementation adapter must receive only inputs/trusted test dependencies,
execute the operations, and compare its actual state/records/receipts to the
expected block. It must never use the expected block to manufacture results.
A missing adapter is an unimplemented capability, not a passing or skipped
behavior test. Clock rollback, archive/seal, concurrent database sessions, raw
body/depth limits, batch-byte limits, and real outbox recovery remain the explicit
service acceptance gates, not claims made by these fixtures.
