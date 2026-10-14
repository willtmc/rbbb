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

**Still required before advertising support:**

- live inventory registration and every operator unit mutation (including voids)
  must use the same durable ordering boundary, with registration fault tests;
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
