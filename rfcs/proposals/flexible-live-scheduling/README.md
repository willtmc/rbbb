# Proposed scheduling contracts

Status: **proposed, not accepted or implemented**. These documents accompany
[the live-scheduling RFC](../../flexible-live-scheduling.md). They do not add an
endpoint, engine command, stable capability, or production-readiness claim.

## Artifacts

- [`minute-batch-examples.json`](minute-batch-examples.json): proposed initial
  schedule examples for minute batches, nonconsecutive groups and proxy-adjustment
  exclusions. Separate from the 26 coordinator vectors; fixture checks are not
  scheduler implementation tests.


- [`service-contract.md`](service-contract.md): selected auction-row ordering,
  atomic records/receipts, retry/archive rules, replay mapping and resource profile.
- [`submission.schema.json`](submission.schema.json): untrusted intent without
  caller-supplied principal or authoritative time.
- [`resource-profile.json`](resource-profile.json): proposed machine-readable
  ceilings, not load-certification evidence.
- [`behavior-vectors.md`](behavior-vectors.md): 26 vectors / 44 steps with exact
  expected states and records, covering the original 18 review cases. The new FLS-19/20 planning and
  proxy-adjustment examples are separate and still need coordinator vectors. Coordinator
  execution remains unimplemented.

- [`contract.schema.json`](contract.schema.json): JSON Schema 2020-12 union of
  command, public-change, privileged audit, notification-intent, and rejection
  documents. Individual definitions are addressable under `$defs`.
- [`merge-example.json`](merge-example.json): invented contract-shape example of
  a merge that extends some units and deliberately shortens another. Its audit,
  public change, and notification intent share one commit identity. The separate
  rejection example illustrates the alternative failure document; it is not an
  additional event emitted by the successful operation.
- [`../flexible-live-scheduling-scenarios.md`](../flexible-live-scheduling-scenarios.md):
  the human-readable review cases underlying the new behavioral vectors.

The provisional capability token is `flexible_live_scheduling_draft_1`. Unknown
or unsupported capability tokens must not fall back to baseline independent
schedule edits. This token is not a supported capability declaration by the
current Ruby engine.

## Proposed command shape

Both `revise_closing_schedule` and `reconfigure_closing_groups` include:

- command/auction/operator IDs and authoritative effective time;
- `expected_schedule_revision` and a nonempty `expected_units` version vector;
- a nonblank privileged reason and an explicit `allow_shortening` boolean;
- `resulting_closing_sets`, the complete requested partition of affected units;
- `retired_group_ids`, explicitly empty when no groups are retired.

A closing set has `group_id`, member unit IDs, closing time, and an explicit
extension policy (or null to disable automatic extension). A null group ID
means exactly one standalone member, not an unnamed multi-unit group. Group
IDs and member lists cannot implicitly borrow another group's policy.
`revise_closing_schedule` cannot retire groups or change membership; the latter
condition needs current-state validation, not merely JSON Schema.

The proposed identifier length cap is 128 characters; the privileged reason cap
is 2,048 characters. Revisions and durations reuse the baseline safe-integer
bound; time reuses its explicit-offset, at-most-millisecond contract. Positive
extension duration is enforced structurally. The proposed service profile sets a 4,096-unit ceiling, 4 MiB submission and
16 MiB encoded-batch bounds, and a 16-level parsing bound. Schema checks enforce
submitted membership/vector cardinality; actual parsing, discovered-set and
batch-byte admission guards require the future service implementation. A
promised atomic edit may not be split to fit them.

## Trust and publication boundary

An operator ID, reason, and `allow_shortening: true` express requested intent,
not authority. Authentication and operation-specific permission checks occur at
the trusted host/service boundary. A caller-supplied `authorized` field is not
part of the command schema and is rejected as an unknown property.

The public-change document includes only topology, scheduling, versions, and
opaque commit/command identifiers. It cannot contain an operator identity or
reason, bidder identities, private maxima, reserve values, or proxy positions.
The audit document retains operator reason and the before/after scheduling
state; it does not duplicate the units' private bid histories.

Notification intent identifies affected units and change categories. The host
resolves `affected_participants` against its authorized registrations, bidder
activity, and subscriptions; the engine does not enumerate email addresses or
send messages. A committed edit and a delivered notification remain different
facts. Neither public projection nor notification intent authorizes exposure of
unpublished inventory.

## Shape validation is not behavior validation

Run the existing test task to execute the proposal's positive and negative
contract checks:

```sh
cd ruby/engine
bundle exec rake
```

`test/flexible_scheduling_proposal_test.rb` validates the five document kinds,
example receipt linkage, safe-integer limits through chained references,
nonblank reasons, member uniqueness/cardinality, explicit shortening intent,
timestamp precision, and private-field rejection. The dependency-free schema
checker now exercises numeric/string/array bounds and chained-reference cycles
instead of silently ignoring those keywords.

These tests **do not run scheduling operations**. In particular, schema-valid
`allow_shortening: false` is not proof that the requested deadline is safe;
comparing that request to old state belongs to the future coordinator. The
following remain semantic guards and behavioral conformance requirements:

- complete affected-set discovery and unchanged membership for schedule-only edits;
- matching revisions, no duplicated unit identities in version vectors, and no
  unit assigned across multiple closing sets;
- future deadlines, elapsed/closed-unit rejection, and monotone authoritative time;
- authorized shortening, exact retirement sets, and no-change handling;
- preservation of prices, executed floors, priorities, and all accepted bids;
- bid/edit races, atomic group extensions/closing, durable outbox, and idempotent retries;
- revision exhaustion: never emit an incremented revision outside the safe range.

The proposed `no_change` rejection avoids creating a new scheduling revision or
notification intent for an edit with no scheduling effect. Retries of an already
accepted command still return the original receipt. Rejection precedence and resource bounds are now specified in the proposed
service contract. They still require implementation and behavioral verification.

The proposal stays outside `specification/` and the accepted executable
`conformance/scenarios/` suite until those requirements are fulfilled. Existing
package contents, RFC 0001 behavior, and baseline conformance claims are unchanged.
