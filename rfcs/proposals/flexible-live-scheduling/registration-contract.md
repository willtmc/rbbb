# Live unit registration — accepted RFC 0004 addendum

Status: **accepted by Will McLemore, 2026-10-14; reference implementation complete; deployment certification separate**.
Maintainer accepted the standalone-first design, trusted `register` permission,
creation/delta records, version-0 exception and `unit_id_conflict`, with the
explicit null-clock replay clarification below. Acceptance does not authorize
release, capability advertising or live bidding.
This adds a creation envelope and replay mapping to the accepted
[service contract](service-contract.md). It does not change the accepted
RFC 0001 command/event union, advertise a capability, or certify a host.
Synthetic acceptance cases are in [registration-cases.md](registration-cases.md).

## Boundary and existing decisions

RFC 0004 §1 already permits new empty units after bidding begins, requires an
intended schedule before bid acceptance, and uses the existing guarded operation
for group attachment. Service-contract §§1–6 already require auction-scoped
ordering, atomic receipts/events/outbox, authenticated replay, scheduling revision
advancement for registered membership, and complete-commit projection.

The addendum below supplies missing registration-specific fields, records and replay
rules. These registration-specific choices were accepted on 2026-10-14. They extend
the coordinator contract, not the baseline RFC 0001 command union.

## Submitted intent

A closed object contains exactly:

- `type`: `register_unit`;
- `command_id`, `auction_id`, `unit_id`: identifiers under the existing 128-character rule;
- `expected_schedule_revision`: the existing safe nonnegative integer;
- `configuration`: the complete baseline
  [timed-proxy configuration](../../../specification/configuration/timed-proxy.schema.json);
- `reason`: the existing nonblank privileged reason, at most 2,048 characters.

No submitted state, unit version, operator identity, time, capability, membership,
or group ID is allowed. Configuration carries the intended standalone deadline
and extension policy; there is no second competing scheduling object.
Configuration validation includes the baseline semantic rules, not just schema
shape. Reject unknown/duplicate properties and invalid text before sequencing.
Normalize timestamps and use the service-contract principal-bound fingerprint.
Trusted deployment supplies tenant/auction context, authenticated principal,
current `register` permission and authoritative ordered time.

One command creates exactly one standalone unit. Group attachment is a subsequent
`reconfigure_closing_groups` command with current schedule/unit versions. The host
may withhold catalog visibility and bid admission until that attachment commits;
this draft does not promise atomic create-and-attach. If atomic creation of several
units or creation directly inside a group is needed, it needs another reviewed
contract rather than splitting an allegedly atomic request.

## Ordered decision

Use the existing auction ordering boundary and validation precedence. After
retained-receipt resolution, sealed/capability and permission checks, apply:

1. Operation resource bounds (one affected unit and one resulting closing set;
   request/depth and encoded-batch bounds remain the accepted profile).
2. Exact `expected_schedule_revision` match, otherwise `stale_revision`.
3. A never-registered `unit_id`, otherwise `unit_id_conflict`.
   A different command ID cannot reset or replace an existing unit, including a
   terminal unit or an unpublished/catalog-removed unit. No identity reuse.
4. A valid configuration whose deadline is strictly after both its opening and
   authoritative time, otherwise `invalid_schedule`. A future opening is allowed.
5. Scheduling revision below the safe-integer ceiling, otherwise `version_exhausted`;
   then the complete encoded-batch bound, otherwise `resource_limit_exceeded`.

Invalid configuration shapes/semantics are pre-admission failures. Rejections
inside the ordered decision retain receipts without changing domain state.
`unit_id_conflict` is the accepted finite registration rejection reason in the
existing closed `closing_change_rejected` envelope. It carries no configuration,
identity diagnostics or private fields.

The successful state consists of:

- configuration installed durably under the new immutable unit identity;
- the baseline `Engine.initial_state` / `State.empty(configuration)`, version 0,
  empty positions/history, no bidder/leader/outcome and `last_effective_at: null`;
- one standalone closing set with null group ID, the new sole member, and the
  configuration's deadline/extension;
- scheduling revision advanced exactly once; all previous units/sets unchanged.

Registration is aggregate creation, not a fabricated bid or a baseline unit
command. Version 0 is deliberate: later accepted commands advance it normally.
The auction's ordered clock and private decision sequence advance at registration;
the new unit's baseline last-command time remains null until its first command.

## Atomic records and replay

A successful commit atomically stores configuration, state/topology, receipt,
private sequence/time, and the following domain/outbox records in fixed order:

0. `bidding_unit_registered`, privileged: capability, type, visibility,
   command/commit/auction/unit IDs, effective time, trusted operator ID, reason,
   complete configuration and baseline empty state.
1. `closing_configuration_changed`, public: the existing closed scheduling
   record with the new scheduling revision, new unit's version 0, standalone
   resulting closing set, and empty retired-group list.

The registration record is a coordinator creation record, **not** a `{unit_id,
event}` baseline event. No manual scheduling audit/notice or synthetic bid is
emitted. Record identity is `(commit_id, record_index)` as usual. A registration
receipt remains privileged; the ordinary authorized response exposes only the
public record. Configuration, reserve, operator/reason and complete state must
never appear in public projection or its digest. Catalog visibility is still a
host authorization check, not permission granted by this event.

Privileged replay requires the entire two-record batch. Validate identity,
configuration, exact empty state, version 0, matching schedule, next scheduling
revision and absence of the unit in the before-state. Install configuration and
empty state before applying the scheduling delta. Registration is the explicit
exception to the ordinary existing-unit 'advance once' replay rule; the created
unit stays at version 0 **and `last_effective_at: null`**. Neither ordinary
scheduling-delta version advancement nor its commit-time assignment applies to
the newly created unit. The auction decision clock still advances normally.
Reject a missing, reordered, conflicting or partial
creation batch without mutation. Audit replay does not need live register
permission; it needs separately authenticated privileged replay authority.

Public consumers cannot derive private state/configuration from this batch. They
must atomically install the authorized public scheduling projection or resync to
a consistently authorized public snapshot. Baseline-only consumers reject the
unsupported coordinator capability. Stable outbox redelivery must not recreate
the unit or repeat admission. Reopening a host loads the durable configuration
registry; caller bootstrap configuration is not permission to erase new units.
Changing a previously registered configuration is outside this addendum.

## Execution gate

The accepted registration envelope and creation record have separate closed
schemas in [registration.schema.json](registration.schema.json); baseline command
and scheduling command/event unions remain unchanged; the existing rejection
reason enum additionally accepts `unit_id_conflict`. Contract tests validate their
shapes and exact synthetic empty-state oracle, not registration execution.
The [21-case execution map](registration-cases.md#execution-map-reference-host-not-certification)
records coordinator/host, race, crash, projection and snapshot-recovery evidence.
The bounded reference implementation is complete; deployment-specific identity,
policy and recovery certification remain necessary before capability advertising.
Acceptance and schema tests alone cannot establish implementation conformance.
