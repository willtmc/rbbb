# Live scheduling implementation (unreleased, not certified)

This implements the accepted [RFC 0004](../rfcs/0004-flexible-live-scheduling.md)
operator-edit, bid/linked-extension and group-close decisions. It is **not** a
production-ready host and does not advertise `flexible_live_scheduling_draft_1`.
The published RFC 0001 engine and capability metadata remain unchanged.

## Code and entry points

- `ruby/engine/lib/rbbb/live_scheduling.rb` is an explicit optional require; it
  does not change baseline `RBBB::Engine` behavior or add runtime dependencies.
- `LiveScheduling::Intent` accepts only the closed scheduling submission shape,
  rejects duplicate JSON keys/set members and unknown/server-assigned fields,
  and fingerprints normalized intent with SHA-256 over RFC 8785 canonical JSON.
  Timestamps normalize to UTC milliseconds; reasons are retained verbatim.
- `LiveScheduling::Coordinator` computes a complete detached decision from a
  consistent auction snapshot. Operator edits discover old and target groups,
  enforce version/topology/eligibility/shortening guards and emit the three
  ordered audit/public/notification records. Bids preserve independent pricing
  while synchronizing linked deadlines. Group close computes every outcome
  before returning any mutation. A rejection has no domain records or changes.
- `LiveScheduling::Projector` replays a complete **privileged** commit, applies
  native unit events before its scheduling delta, and refuses partial groups,
  revision gaps, conflicting versions and incorrect group retirement.
- `examples/live_scheduling_host.rb` persists snapshots, private receipts,
  immutable event batches, a private decision sequence and outbox intent in
  one SQLite transaction. `BEGIN IMMEDIATE` fences every implemented entry point
  across processes/connections. This database-wide fence is intentionally
  stronger/coarser than the reference auction-row lock, not a scalability claim.

The SQLite adapter is embedded, **not HTTP**. `principal_id`, permissions, clock,
tenant and commit identity must be supplied from trusted host context. Never
populate them from a public request body. Its snapshots, receipt records and
outbox delivery seam are privileged: they can contain private maxima/history.
Use `public_view` for the unit public projection; public subscribers refetch a
consistent authorized snapshot rather than applying private baseline events.

The host resolves receipts before allocating fresh time. Replay preserves its
original complete receipt after deadlines/sealing and creates no events/outbox
records. Changed intent cannot overwrite an ID. Different principals and
revoked permissions cannot retrieve its private contents. New commands clamp
clock rollback to the last durable decision time. Sealing is atomic; there is
no unseal/receipt-TTL shortcut.

`deliver_pending` gives a trusted consumer one whole committed batch with stable
`(commit_id, record_index)` identities. It calls the consumer outside the write
transaction, then acknowledges delivery separately. A crash can redeliver the
same batch; the consumer must deduplicate. Delivery never reruns a command.
No test sends messages or contacts a customer.

## Registration reference-host slice (not certified)

`Intent.parse_registration` validates the accepted closed registration envelope,
including nested configuration shape/semantics, duplicate keys and request/depth
bounds. `Coordinator.register_unit` returns a detached standalone creation with
version 0, null unit clock, one revision advance and the privileged/public record
pair. On success, `Result#configurations` contains the proposed updated registry;
a host must commit it atomically with state, receipt and outbox. It is not an
in-place registry mutation. Rejections return no proposed registry.

Run `cd ruby/engine && bundle exec ruby -Itest test/live_registration_test.rb`.
The tests exercise creation, schema/privacy, closed admission, identity conflict,
permission/stale/time/version/batch rejection and detached state preservation.
These are pure runtime tests, **not** full REG01–21 execution or certification.
The SQLite host now exposes `register_unit(intent:, principal_id:, permissions:)`
inside its existing transaction/receipt/outbox boundary. Successful creation also
persists `Result#configurations` in that transaction. Reopening validates bootstrap
policy/profile and seed configurations against the stored registry, retaining all
subsequently created units; bootstrap input cannot erase them. `configurations`
is a privileged detached registry read, not a public API.

For whole-commit replay use `Projector.apply_commit(snapshot:, configurations:,
records:, policy:, auction_id:, profile:)`; atomically install BOTH returned
`"snapshot"` and `"configurations"`. Creation is rederived from the accepted pure
contract and must exactly match the complete ordered two-record batch, including
empty private state, version 0 and null unit clock. The legacy state-only `apply`
refuses creation rather than silently losing its configuration registry. Caller
inputs are never mutated. Replay authority is a trusted host responsibility, not
live register permission or an untrusted body field.

`live_scheduling_host_test.rb` covers reopen/new-unit bidding, retained receipt
identity/permission checks, conflicting intent and bootstrap changes, rejection
preservation, rollback, independent-process registration race, SIGKILL before and
after commit, outbox-ack crash/redelivery, sealed database copy/restore, and
partial/reordered/conflicting creation replay. This is bounded reference-host
evidence, **not** complete REG01–21 or authenticated deployment certification.
Do not expose this through a live endpoint or advertise the capability.

## Evidence and remaining certification gates

Run `cd ruby/engine && bundle exec rake` (tests plus installed-package smoke).

`live_scheduling_coordinator_test.rb` executes **all 29 supplied vectors / 47
steps**, comparing complete state, exact ordered records and retained/replayed
receipts. Initial unit state is independently seeded through the baseline
engine. Fault-before-commit rolls back SQL; fault-after-commit reopens the
adapter before asserting durable state. Expected results are never inputs to
the coordinator. The original fixture labels describe proposal provenance,
not whether this implementation has been certified.

`live_scheduling_limits_test.rb` executes FLS-19's full 4,096-unit merge/split
and FLS-20's boundary rejection, raw-body and fully encoded domain/outbox byte
limits, no-change and revision exhaustion. `live_scheduling_host_test.rb`
uses two independent processes/database sessions for edit/edit, bid/edit and
close/edit races, and tests identity/permission replay, clock rollback, sealing,
no partial rejection effects and outbox retry. Additional independent-process
`SIGKILL` tests interrupt an edit immediately before SQL commit, immediately
after durable commit, and after outbox delivery but before acknowledgment.
Reopening verifies rollback or complete retained receipts/events/outbox as
appropriate, plus stable whole-batch redelivery. A quiescent sealed-database
copy/restore test preserves accepted and rejected receipts, authorization,
command identity, pending delivery and the sealed mutation boundary. These are
SQLite reference-host tests, not deployment/load certification.

Operator `void_bid` now shares the reference host's durable transaction,
principal-bound receipt index and outbox. The host assigns operator identity and
time and requires a current `void` permission, including receipt replay. Voids
use the existing engine semantics without extending a linked group's deadline.
Tests cover retained replay, denied disclosure, changed-intent refusal and atomic
rollback of state, receipts, history and outbox. A real independent-process SIGKILL
immediately before and after void commit verifies rollback versus retained state,
sealed receipt replay without clock allocation, unchanged scheduling and exactly
one acknowledged pending void batch after reopen. This is reference-host crash
evidence, not deployment certification or a public admission API. Independent-process
void/edit and void/close tests additionally verify retained accepted/rejected receipts,
closed-unit preservation and exact journal replay. The edit may reject as stale when
void changes its expected unit version; void does not change scheduling revision.

Operator `change_reserve` also uses this boundary with current `reserve`
permission, server-assigned identity/time, principal-bound replay and the
baseline engine's reserve rules. It advances the unit, not scheduling revision,
and does not change closing sets or extend deadlines. Tests cover revoked/wrong
principal replay, changed intent, spoofed fields, atomic rollback/retry,
independent-process reserve/bid ordering and SIGKILL before/after commit.
Rejected commands retain receipts and decision time/order but preserve the
stored domain snapshot byte-for-byte (including timestamp representation).
Single-unit baseline closing-time writes are deliberately not exposed: live
schedule changes must use the complete affected-set scheduling edit API.

The [registration execution map](../rfcs/proposals/flexible-live-scheduling/registration-cases.md#execution-map-reference-host-not-certification)
links each REG01–21 obligation to named runtime/host checks and explicit gaps.
Additional host tests cover exact existing-state preservation, retained late
replay without clock allocation, closed admission with full database-row
comparison, standalone-then-attach, and registration/edit, existing/new-unit bid
and close races in independent processes. Committed batches replay to the exact
durable registry/state. Accepted operations now preserve closing sets outside
the scheduling delta exactly, rather than silently reformatting timestamps.

REG-20 host tests now exercise exact request byte/depth admission, plus-one
admission refusal without any durable bookkeeping, exact encoded-batch admission,
retained batch-overflow and revision-ceiling rejections, and reopened replay
without a new clock allocation or sequence increment. REG-21 corruption tests
remove newly registered configuration, accepted/rejected receipts, commit history
or outbox rows from synthetic archives. Reopening and submitting through an
already-open host both refuse these incomplete stores before receipt disclosure
or time allocation. This includes loss of a rejected receipt in an unsealed store.

`LiveSchedulingHost` cross-checks registry/unit identities, decision count versus
receipt count, and journal batches against their retained responses and complete
outbox rows on reopen and every submission. This deliberately simple reference
check scans retained history; it is not a scalable deployment storage design, an
authenticated archive manifest, or protection against a coordinated rewrite of
all evidence (including the decision count). Do not repair a failed archive by
resetting counters, deleting more history or re-seeding the auction: recover a
complete trusted copy. Deployment manifest/recovery certification remains open.

### Trusted snapshot reader (reference integration only)

`examples/live_scheduling_reader.rb` wraps the privileged host with server-owned
`authenticate`, `authorize`, and per-unit `visible` callbacks. A transport calls
`reader.checkpoint(credential: token, visibility: "public")` after installing
those callbacks; tokens/roles must not be treated as permissions themselves.
Every refetch authenticates again. Authorization and catalog checks run within
the same host transaction as the snapshot and decision sequence. Only literal
`true` grants access. Callback errors propagate without disclosing a snapshot.

Public output contains only visible units' baseline `public_view` plus scheduling
revision, not private state or full topology. It is a refetch-only view, not input
to the privileged projector. Privileged reads require access to every unit and
return a detached complete snapshot. Each response hashes only its own authorized
payload; a public response never includes a privileged digest. Decision sequence
is a snapshot checkpoint (including rejected decisions), not a contiguous event
stream cursor. Applications must install snapshots atomically and must not reuse
these responses across principals or use them to infer missing commit history.

Run `cd ruby/engine && bundle exec ruby -Itest test/live_scheduling_reader_test.rb`.
Expected: four tests covering denial/revocation, strict grants, catalog filtering,
separate digests, detached private reads and post-commit revision/checkpoints.
This is not identity-provider authentication, a command admission adapter,
authorized commit manifests, persistent consumer recovery or deployment
certification. Those gates remain open; no capability or live-use change.

### Trusted command admission example

`examples/live_scheduling_admission.rb` wraps the six existing mutation entry
points with server-owned `authenticate`, `authorize` and `permissions` callbacks.
Construct it with the host and those callbacks, then call e.g.
`adapter.bid(credential: token, unit_id: id, command: command)` instead of passing
request-derived principal IDs or permission arrays to the host. `edit` requires
`schedule`; registration, bid, void, reserve and close require their respective
existing grants. `shorten` remains a separate host-enforced grant.

Every call, including a receipt retry, resolves identity and current grants again.
Only literal `true` authorizes access; client authority keywords are refused.
Callbacks must authorize the full auction/action scope before granting access;
the host continues to enforce closed intent, unit versions and ordered semantics.
This adapter is trusted in-process glue, not an identity provider, unit-scoped
policy engine, transport parser, public endpoint or deployment certification.

Run `cd ruby/engine && bundle exec ruby -Itest test/live_scheduling_admission_test.rb`.
Expected: four tests exercise all six dispatches, strict denial, revoked retries
and spoofed authority against a recording host. These are adapter unit tests,
not end-to-end authenticated deployment tests. Keep direct host references private
to the embedding service; exposing them would bypass this boundary. Commit-stream
manifests and persistent resynchronization/cursor recovery remain unimplemented;
the reader checkpoint must not be used as a contiguous stream cursor.

The [consumer recovery draft](../rfcs/proposals/flexible-live-scheduling/consumer-recovery-contract.md)
proposes snapshot-replacement-first recovery and authorization-context invalidation,
with ten review cases. It is not accepted or implemented; incremental stream
cursor/envelope rules remain deferred pending a separate explicit contract.

**Still required before advertising support:**

- complete the registration REG01–21 execution matrix and mutation-entry-point
  inventory beyond the implemented reference-host ordering/recovery slice.
  The [registration addendum](../rfcs/proposals/flexible-live-scheduling/registration-contract.md)
  and [21 synthetic review cases](../rfcs/proposals/flexible-live-scheduling/registration-cases.md)
  record the creation/replay contract accepted by Will on 2026-10-14, including
  preservation of both version 0 and null unit last-command time during replay.
  Closed intent/creation schemas and executable contract/privacy/empty-state
  checks and bounded runtime/host/replay tests exist, but the full 21 execution
  gates have not passed;
- deployment-specific void concurrency certification remains beyond the reference-host
  void/edit and void/close races, transaction/replay/rollback and commit crash coverage;
- extend the reference-host edit crash and sealed-copy recovery evidence to
  every remaining mutation entry point and deployment archive/restore workflow;
- a deployment's authenticated admission layer, public/private projection
  manifests and authorized consumer resynchronization must be certified;
- finalize `specification/` integration and migration contract before capability
  advertisement. The accepted proposal schemas remain the current contract.

These explicit gaps mean this change is an implementation slice, not closure of
issue #45, not a release, and not permission for shadow/pilot/live bidding.

## Migration boundary

Do not install this optional component behind an existing RFC 0001 engine and
silently accept new operations. A host must choose its ordering/persistence
boundary, immutable resource profile and positive shortening lead before
accepting scheduling commands. Seed stable units and their complete closing-set
partition from a consistent authorized snapshot; never reconstruct private bid
state from public projections. Preserve receipt identities/history and retired
group IDs. Baseline-only consumers must reject the unsupported capability.

Complete and record all remaining gates before changing a host's advertised
capabilities. Profile/policy changes belong only to new auctions or an explicit
sealed migration boundary. No automatic production migration is provided.
