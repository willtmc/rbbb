# Optional flexible live scheduling coordinator

Status: accepted RFC 0004 contract; unreleased reference implementation;
**service certification incomplete**. This document maps already accepted
requirements; it does not activate `flexible_live_scheduling_draft_1`, extend
the RFC 0001 command/event unions, or certify any implementation or deployment.

## Contract sources and boundary

[RFC 0004](../rfcs/0004-flexible-live-scheduling.md) governs the optional
auction-scoped coordinator. Its accepted
[service contract](../rfcs/proposals/flexible-live-scheduling/service-contract.md)
defines ordering, identity, retention, validation precedence, resource bounds,
atomic publication and acceptance gates. The accepted
[registration addendum](../rfcs/proposals/flexible-live-scheduling/registration-contract.md)
and [snapshot recovery addendum](../rfcs/proposals/flexible-live-scheduling/consumer-recovery-contract.md)
supply creation and authorized recovery requirements respectively.
The files remain at their RFC paths to preserve schema IDs and relative references.
Their historical proposal labels are not evidence of certification or capability
support. The accepted RFC and addenda determine their scope.

A baseline unit still uses the existing configuration, commands, state and events.
The coordinator supplies the surrounding auction transaction, scheduling revision,
closing-set partition, registry, retained receipts and complete commit boundary.
Every mutation of that auction must participate in the same ordering boundary;
independent per-unit transactions are not equivalent for linked closing groups.

## Language-neutral record and envelope mapping

Record identity is `(commit_id, record_index)` across one complete ordered batch.
Coordinator records are **not** RFC 0001 event envelopes. Do not insert them into
the baseline event union or manufacture baseline commands to represent them.

| Decision | Complete ordered records | Replay mapping |
| --- | --- | --- |
| Accepted manual scheduling edit | `closing_configuration_committed` (privileged audit), `closing_configuration_changed` (public scheduling delta), `closing_change_notice` (privileged notification intent) | Apply the complete affected-set delta once; audit and notice do not apply another mutation. |
| Bid or grouped close | `{unit_id, event}` baseline records ordered by unit ID, then baseline decision-event order; one trailing `closing_configuration_changed` only if scheduling revision advanced | Apply baseline events first, then the complete scheduling delta. |
| Baseline operator void or reserve change | Existing baseline decision events carried in the coordinator's unit-record batch | Preserve baseline semantics; these are not manual schedule edits and do not extend linked deadlines. |
| Registration | `bidding_unit_registered` (privileged creation), then `closing_configuration_changed` | Install configuration and exact empty baseline state, then the delta; preserve the new unit's version 0 **and null `last_effective_at`**. |
| Rejected ordered decision | Retained private receipt; no domain records or domain mutation | Retry resolves the original receipt under current authority; it does not rerun the decision. |

Closed field shapes are defined by the accepted RFC artifacts:

- [submitted scheduling intent](../rfcs/proposals/flexible-live-scheduling/submission.schema.json);
- [authoritative scheduling command, public change, audit, notice and rejection](../rfcs/proposals/flexible-live-scheduling/contract.schema.json);
- [registration intent, creation and empty state](../rfcs/proposals/flexible-live-scheduling/registration.schema.json).

The bid entrypoint can also execute baseline `reduce_maximum`; preserving its
private audit and baseline version change does not imply a scheduling revision
or deadline change. Baseline events retain their existing visibility rules;
wrapping a private event in a unit record never makes it public.

For ordinary affected existing units, the delta declares the resulting unit
version, closing time and commit effective time. Units advanced by baseline
events must match that version; other affected units advance exactly once.
Registration is the explicit version-0/null-clock exception. Replace affected
closing sets, retire named groups and preserve unaffected sets and unit fields.
Install configuration and state together. Refuse partial, reordered, conflicting
or revision-gapped batches rather than repairing them. Replay authority is
separate from authority to execute a new live command.

## Public reads, recovery and delivery

Public consumers cannot reconstruct private engine state from scheduling deltas.
Use complete authorized projections or consistent authorized snapshots; never
strip fields from a privileged batch and assume the remainder is a public stream.
Public and privileged payloads have separate authorization and content digests.
A public response must not disclose a privileged payload fingerprint.

The accepted recovery path is snapshot replacement first: atomically install
payload, checkpoint and its own digest, scoped to tenant/auction, visibility and
host-owned authorization context. Reauthenticate and reevaluate catalog/policy
on every fetch, including retries. Revocation prevents serving the old view;
a policy-generation change replaces the whole installation. Identical retries
are no-ops; conflicting content at the same installation identity fails closed.
A private decision sequence includes rejections and is **not** a contiguous
commit-stream cursor. Incremental epochs, successors and cursor envelopes remain
deferred pending separate acceptance, not prerequisites invented by this mapping.

Outbox publication is at least once with stable record identities. Retry does
not rerun the auction mutation. Snapshot installation is not evidence that an
external notification was delivered. If notifications are enabled, freeze the
delivery plan, deduplicate recipient/channel/intent identities and retain separate
delivery evidence as required by the service contract.

## Migration and certification boundary

This optional contract is not a transparent upgrade to an RFC 0001 endpoint.
Before accepting scheduling operations, an embedding must select its ordering
and persistence boundary, immutable resource profile and positive shortening
lead. Seed the complete configuration registry, private unit states and closing-set
partition from a consistent authorized source, not public views. Preserve unit,
command, receipt and retired-group identities and retained history. New-unit
registration is standalone first; if group attachment was promised, visibility
and bid admission remain a host responsibility until that separate guarded edit
commits. No atomic create-and-attach operation is implied.

Profile/policy changes apply to new auctions or an explicit sealed migration
boundary. A baseline-only consumer rejects the unsupported capability. No automatic
production migration, capability advertisement or live-use permission is supplied.

Executable evidence and limitations are indexed in the
[implementation guide](../docs/live-scheduling-implementation.md#evidence-and-remaining-certification-gates)
and [REG01–21 map](../rfcs/proposals/flexible-live-scheduling/registration-cases.md#execution-map-reference-host-not-certification).
The coordinator tests execute supplied behavioral vectors; whole-journal tests
check reference replay, including registration and maximum reduction. This
mapping documents the portable contract, but does not establish independent
cross-implementation execution or deployment certification. Service-contract §7
acceptance gates remain authoritative. Real identity/policy consistency,
deployment concurrency/load, authenticated complete archive/restore and any
notification delivery workflow still require deployment-specific evidence.
