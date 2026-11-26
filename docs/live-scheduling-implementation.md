# Live scheduling reference implementation

The bounded RFC 0004 reference implementation is complete for source-based
synthetic evaluation: mutable linked closing groups, registration, linked bid
extensions, independent per-unit outcomes, durable command ordering and
snapshot-first recovery. This completes the engine work in issue #45.
It does not certify a deployment, publish a release or authorize live bidding.
The baseline RFC 0001 engine and its advertised capabilities remain unchanged.

Governing rules: [AGENTS.md](../AGENTS.md), [RFC 0004](../rfcs/0004-flexible-live-scheduling.md),
its accepted [service contract](../rfcs/proposals/flexible-live-scheduling/service-contract.md),
[registration addendum](../rfcs/proposals/flexible-live-scheduling/registration-contract.md)
and [snapshot recovery addendum](../rfcs/proposals/flexible-live-scheduling/consumer-recovery-contract.md).
The language-neutral [specification mapping](../specification/flexible-live-scheduling.md)
defines how complete ordered records map to state and migration requirements.

## Integration surface and version

`require "rbbb"` then `require "rbbb/live_scheduling"` loads the dependency-free
optional core. Construct `RBBB::LiveScheduling::Coordinator` with `auction_id:`,
`configurations:`, `snapshot:`, `policy:` and optional immutable `profile:` and
`retired_group_ids:`. A snapshot contains `schedule_revision`, `units` and the
complete `closing_sets` partition. Each accepted decision returns detached
`state`, ordered `records`, `retired_group_ids` and, for registration, the updated
`configurations`. Rejections carry `rejection_reason` and no domain records.

| Method | Submitted operation | Trusted inputs |
| --- | --- | --- |
| `edit` | Closed `revise_closing_schedule` or `reconfigure_closing_groups` intent | Principal, current `schedule`/separate `shorten` grants, effective time, commit ID |
| `register_unit` | Closed standalone creation intent | Principal, current `register` grant, effective time, commit ID |
| `bid` | Baseline `place_bid` or `reduce_maximum`, plus unit ID | Bidder identity, effective time, commit ID |
| `void_bid` | Baseline void, plus unit ID | Operator identity, effective time, commit ID |
| `change_reserve` | Baseline reserve change, plus unit ID | Operator identity, effective time, commit ID |
| `close` | `close_bidding`, exactly one group ID or standalone unit ID | Effective time, commit ID |

The pure core is not the authentication or receipt boundary. Use the durable host
and admission adapter below when those responsibilities are needed. Never call
single-unit `change_closing_time` around the coordinator or apply independent
close commands to a linked group.

`Projector.apply_commit(snapshot:, configurations:, records:, policy:, auction_id:)`
returns both detached registries; install them atomically. The state-only `apply`
rejects registration. Replay requires the entire ordered batch, including native
public/audit companions and every member's close. It refuses missing, reordered,
conflicting and revision-gapped batches. Registration retains version 0 and null
unit command time. Replaying audit history requires privileged authority; it does
not recheck live execution permissions.

**Distribution:** the published `0.1.0.pre.3` gem predates this coordinator.
This source tree still carries that version constant; it is not evidence that
the published artifact contains these files. Pin the reviewed source commit
(and the `ruby/engine` gemspec) for evaluation, or wait for a separately approved
new prerelease. Do not replace an installed/published `0.1.0.pre.3` artifact with
an unlabelled local rebuild. The SQLite examples are repository files, not gem
contents; they require the development `sqlite3` dependency.

## Durable host and authorized snapshots

[LiveSchedulingHost](../examples/live_scheduling_host.rb) implements all six
mutation entrypoints under SQLite `BEGIN IMMEDIATE`, a database-wide fence
stronger/coarser than the contract's auction-row lock. It atomically commits
state, registry, retired groups, immutable records, private receipts, decision
time/sequence and outbox intent. It is not an HTTP service or throughput claim.

Receipts resolve before fresh time allocation. Retained retries preserve their
original response, including rejections, under current principal/operation
authority. Changed intent cannot replace an ID. Clock rollback is clamped.
Sealing is atomic and has no unseal or receipt-TTL shortcut. Reopen/submission
cross-checks retained registry/history/outbox completeness; a coordinated rewrite
of every evidence copy requires a deployment's authenticated archive protection.

`deliver_pending` yields a complete privileged batch outside the write
transaction, with stable `(commit_id, record_index)` identities, then separately
acknowledges it. A crash may redeliver. Consumers deduplicate; delivery never
reruns an auction command. No reference test sends messages.

[LiveSchedulingAdmission](../examples/live_scheduling_admission.rb) resolves
identity and current action/grant callbacks on every command and retry. Only
literal `true` authorizes. Client principal/permission overrides are refused.
Keep the raw host private to the embedding service; callbacks must be trusted,
server-owned policy, not request roles.

[LiveSchedulingReader](../examples/live_scheduling_reader.rb) checks authorization
and catalog visibility in the same transaction as its checkpoint. Public payloads
contain only visible baseline public unit views and scheduling revision; private
state/topology and privileged digests are not exposed. Privileged reads require
access to the whole auction. Each payload hashes only its authorized contents.

[LiveSchedulingConsumer](../examples/live_scheduling_consumer.rb) refetches on
every read, validates scope and digest, and atomically installs the complete
payload/checkpoint/digest. Its opaque server-owned `authorization_context` must
change with principal, visibility or catalog/policy generation. Revocation
invalidates the installation; fetch failures never serve cached data. Identical
retries are no-ops; conflicting content at the same checkpoint is refused.
A decision sequence includes rejected decisions and is not a stream cursor.
Incremental stream envelopes/cursors remain explicitly deferred.

## Acceptance evidence

Run from `ruby/engine`: `bundle exec rake` (all tests and clean installed-package
verification). From the repository root: `ruby scripts/validate_documents.rb`.
All fixtures are synthetic and derive from the accepted public contracts.

| Accepted requirement | Executable reference evidence |
| --- | --- |
| Every FLS behavioral vector | `live_scheduling_coordinator_test.rb`: 29 vectors / 47 steps, exact state, ordered records, retained/replayed receipts and whole-commit projection |
| FLS-14/16/17 failure and race gates | `live_scheduling_host_test.rb`: independent processes/database sessions race bid/edit, edit/edit, close/edit; failures preserve complete state or roll back with no partial domain effects |
| All mutation entrypoints share ordering | Host `submit` transaction covers edit, registration, bid/maximum reduction, void, reserve and close; every entrypoint has before/after-commit SIGKILL and retained recovery tests |
| Receipt retention, sealing and recovery | Host tests cover expiry, original rejection, principal mismatch/revocation, changed intent, sealed copy/restore, pending delivery, acknowledgment and incomplete-store refusal |
| Resource profile | `live_scheduling_limits_test.rb`: full 4,096-unit merge/split, plus-one, raw/encoded byte limits, no-change and revision exhaustion; registration host tests cover exact depth/admission/batch limits |
| Registration REG-01–21 | [Execution map](../rfcs/proposals/flexible-live-scheduling/registration-cases.md#execution-map-reference-host-not-certification): runtime, host, admission, reader and snapshot-consumer checks; deployment-specific obligations identified separately |
| Authorized admission and recovery | `live_scheduling_admission_integration_test.rb`: all six real-host operations and retained retries; reader/consumer suites cover visibility, revocation, scoped digests, atomic replacement and before/after-install SIGKILL |
| Portable mapping and replay | [Specification](../specification/flexible-live-scheduling.md), closed schemas and exact vector/journal replay; `live_scheduling_boundary_test.rb` rejects wrong-route commands and incomplete/reordered/conflicting native batches |
| Packaged integration | `script/verify_package.rb`: clean isolated gem install, baseline bid, linked schedule edit/extension, refusal at old deadline, atomic group close with independent prices and exact replay |

The registration matrix's remaining deployment obligations do not imply missing
reference-engine operations. No independent second-language implementation is
claimed; the mapping and serialized vectors are the interoperable contract.

## Migration and deployment work kept separate

An embedding must select its ordering/persistence boundary, immutable resource
profile and positive shortening lead before accepting commands. Bootstrap the
complete registry, private unit state, closing-set partition, receipt history
and retired-group identities from an authorized consistent source. Public views
cannot reconstruct private bid state. Registration is standalone first; if group
attachment was promised, withhold visibility/bid admission until the separate
guarded attachment commits. Profile/policy changes require a new auction or an
explicit sealed migration boundary. No automatic production migration exists.

Before a deployment advertises `flexible_live_scheduling_draft_1`, separately
verify its identity provider and policy consistency, transport/privacy controls,
actual database concurrency/load limits, authenticated archive/restore workflow,
and any notification delivery plan/evidence. Snapshot-first recovery is the
accepted path; incremental streaming is not a prerequisite. External historical
source-data capture and translation are integration work, not engine semantics.
No production readiness, pilot authorization, release or real-data parity is
claimed by this reference implementation.
