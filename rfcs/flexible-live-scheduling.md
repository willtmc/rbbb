# Proposed RFC: Flexible live scheduling and closing groups

- Status: proposed; not accepted or implemented
- Author: RBBB contributors, for maintainer review
- Created: 2026-09-05
- Specification target: future optional capability; identifier and version unassigned
- Discussion: [issue #33](https://github.com/willtmc/rbbb/issues/33)

## Summary

Opening bidding must not freeze an auction's inventory or closing arrangement.
Operators need to add bidding units, reorganize linked closing groups, and move
announced deadlines earlier or later without republishing the auction or
rewriting accepted bids.

This proposal makes those changes explicit, ordered, atomic, and auditable.
It does **not** change RFC 0001 today. Its post-bid shortening prohibition and
independent-unit model remain the current baseline until a successor capability
is accepted, specified, tested, and implemented.

## Maintainer direction recorded for the next draft

The approved direction is to permit explicit shortening to a strictly future
deadline, leave minimum-notice policy to the host, and keep immediate forced
closing and post-close reopening as separate operations. This resolves those
policy forks without accepting this entire RFC or changing the baseline engine.

Additional maintainer direction: generate initial closing schedules in batches
of N lots per minute, not evenly spaced sub-minute intervals. Soft-close groups
may contain nonconsecutive lot numbers. Default a group's initial deadline to
the latest scheduled deadline among its members, with an explicit override.
Adjusting an existing proxy authorization must not extend closing. These
decisions refine this proposal; they do not accept the entire RFC.

[Proposed machine-readable contracts](proposals/flexible-live-scheduling/README.md)
now define reviewable command, public-change, audit, notification-intent, and
rejection shapes. Their executable tests validate document structure and example
consistency only; there is not yet a scheduling coordinator or behavioral
conformance implementation.

## Policy question

How can a live auction remain editable without allowing a catalog edit to
silently change bidding rights, lose bids, or produce conflicting deadlines?

Flexibility is a supported operation, not a host-side escape hatch. The engine
should express the bidding consequences; the host should own the editing UI,
authorization, catalog presentation, and participant communications.

## Real-world motivation

An operator may open bidding as soon as inventory becomes visible. More units
may arrive later, and related units may need to close together. An exceptional
operational constraint may require a deadline to move earlier, not just later.
A blanket prohibition after the first bid encourages replacement listings and
fragmented histories instead of one inspectable sequence of changes.

The examples in this proposal are invented, non-identifying scenarios. No
private platform records, payloads, or implementations are included.

## Proposed behavior

### 1. Stable units; closing groups do not pool bids

A bidding unit retains its identity, configuration, proxy positions, executed
amounts, priority history, and outcome. Joining or leaving a closing group never
merges its bidders or reallocates bids to another unit.

A closing group is a scheduling relationship among units, not an allocation
format. It has an opaque ID, membership, one shared deadline, one extension
policy, and a revision. A unit belongs to at most one closing group at a time;
an ungrouped unit keeps its own deadline and extension policy. Empty groups are
retired explicitly; their IDs are not reused for unrelated history.

Adding new units remains possible after other units have bids. A new unit starts
with empty bidding state under the normal creation contract. Attaching it to an
existing group uses the same guarded membership operation as any other change.
The host must install its intended schedule before exposing bid acceptance.
Catalog deletion is not permission to delete accepted bidding history.

### 2. Presentation order is not an implicit scheduling command

Changing a title, display position, or catalog grouping in the host does not
change a deadline inside RBBB. If moving a catalog row should alter closing,
the host submits an explicit scheduling command containing the intended result.

This separation permits simple display-only rearrangement without rewriting
bidding state, and lets another host implement a different catalog UX while
using the same engine semantics.

### 2a. Initial closing order and minute batches

The host supplies an explicit ordered list of stable unit IDs, a first closing
time, and a positive integer N for lots per minute. Positions 1 through N
receive the first closing time; positions N+1 through 2N receive that time plus
one minute, and so on. There is no evenly spaced every-60/N-seconds mode in this
proposal. Displayed lot numbers are labels, not arithmetic positions or group
identities: gaps and nonnumeric labels do not change the supplied order.

First assign these per-unit scheduled times, then resolve soft-close groups. A
group's default initial deadline is the latest assigned time of any member.
All its members share that deadline, including members with nonconsecutive lot
numbers. Ungrouped lots retain their assigned times. Group formation does not
compact the remaining minute batches; N controls the initial schedule, not a
guarantee of how many lots ultimately close in any minute after grouping or
extensions.

A host may explicitly override the default group deadline. The resolved time
must be submitted in the scheduling command; the coordinator never guesses it
from member order. Overrides and later recalculation of a live schedule remain
subject to the same future-time, shortening-authorization and expected-version
guards as other schedule changes. Reordering a displayed catalog alone does
not automatically recalculate an already announced live schedule.

See the [minute-batch examples](proposals/flexible-live-scheduling/minute-batch-examples.json)
for synthetic nonconsecutive groups, unchanged intervening lots, and proxy
adjustments. These are proposed examples, not coordinator execution proof.

### 3. Proposed command surfaces

The provisional coordinator operations are:

- `revise_closing_schedule`: change deadlines and/or extension policies without
  changing membership;
- `reconfigure_closing_groups`: join, leave, split, or merge closing groups,
  with explicit resulting schedules for every affected unit/group.

These names are review vocabulary, not released wire contracts. Each request
contains a stable command ID, an authoritative effective time, the expected
scheduling revision, expected versions of every affected unit, an authorized
operator identity, a nonempty privileged reason, and the complete desired result.
The host supplies its authorization decision through a trusted boundary, not a
public caller's self-asserted operator flag.

For membership changes, the affected set is the union of all source and target
group members plus incoming/ungrouped units. The request must account for every
member of that set exactly once in the resulting partition, including units
left ungrouped. A partial member list cannot silently evict another unit.
Membership input order does not establish priority: implementations canonicalize
IDs for event serialization and leave bid priority untouched.

Every resulting group explicitly supplies its common closing time and extension
policy. Every resulting ungrouped unit supplies its closing time and policy.
No implicit choice of the earliest or latest former deadline is allowed. A
caller can explicitly choose the latest deadline, but the choice is visible in
the request and audit record. Units not in the affected set remain unchanged.

### 4. Earlier and later deadlines

After bids exist, an authorized schedule operation may move closing earlier or
later. It preserves all accepted bids, private maxima, prices, executed floors,
and bidder priorities. It cannot undo a bid that was already accepted.

A request that shortens any affected unit's deadline must explicitly declare
`allow_shortening` and pass the host's distinct shortening authorization.
Without that declaration, the entire operation is rejected. A boolean does not
authenticate its sender: the reference service must enforce separate operation
permissions, and an embedded host has the same obligation before calling the
core. The expected versions bind approval to the inspected state; a new bid or
concurrent edit makes that preview stale rather than silently broadening it.

The proposed scheduling operations accept only new deadlines strictly later
than their authoritative effective time and the unit's opening time. They do
not backdate closure, and they do not provide a disguised immediate-close
operation. An already elapsed deadline cannot be extended through a late
schedule edit merely because a background close command has not run yet.
Already closed units are also ineligible. Immediate forced closing and
post-close reopening require separate explicit decisions (see open questions).

A host should show old/new deadlines, affected units, existing bid activity, and
shortening consequences before confirmation. RBBB specifies the guarded
operation and audit contract, not the number of UI clicks or a particular screen.

### 5. One authoritative order across the affected scope

A bid that can extend a group and a command changing that group's membership
must participate in the same authoritative ordering boundary. Locking only the
edited unit is insufficient. The service must validate the scheduling revision,
all affected unit versions, and current membership, then atomically commit all
resulting unit/group state and events or commit none of them.

If topology changed while discovering the affected set, the operation must
retry discovery or reject as stale; it must not lock an incomplete old set.
An accepted retry with the same command ID returns the original receipt, not a
second mutation. Different content under a retained command ID is rejected.
The [proposed service contract](proposals/flexible-live-scheduling/service-contract.md)
requires receipts throughout the mutable auction lifetime and sealing before
archival; restored mutation requires restored deduplication history.

When a bid orders first, it uses the old topology. A later scheduling command
must observe the resulting versions and deadline or fail its preconditions.
When reconfiguration orders first, a later bid uses the new topology. Equal
millisecond timestamps do not create a tie: authoritative command order decides.
Client timestamps never choose that order. Authoritative time cannot precede
any affected unit's last accepted command time.

No SQL implementation is mandated by this proposal. An auction-scoped sequencer
or correctly fenced multi-unit transaction may satisfy it. A collection of
independent, unfenced per-unit writes does not.

### 6. Linked extension and closing behavior

Within a group, apply RFC 0001's qualifying-bid rule using the group's shared
trigger window and duration. If a qualifying bid extends closing, the proposed
new group deadline is the greater of the current group deadline and the
command's effective time plus duration. Every member changes in the same
atomic transition. Adjustments to an existing proxy authorization, including increases or
reductions of its maximum, do not reset an individual or group closing clock.
This exclusion is about the operation's meaning, not merely whether its public
projection changes. A new competing bid may qualify under the accepted bidding
rules; a proxy adjustment must not be relabeled as a new bid to extend time.
The future capability must specify and test that distinction before support is
claimed; this text does not change the current baseline engine.

Changing membership or manually editing a schedule is not a bid and does not
itself trigger a second automatic extension. The explicitly requested deadline
is the result of that operation, subject to validation above.

A group close is ordered against bids and reconfiguration in the same scope.
It commits terminal outcomes for its current members atomically, each priced
from that member's own bid state. It does not pool winners or proceeds. A prior
qualifying bid that extended the group makes a close attempt at the old deadline
too early. No completed group member may be silently revived by regrouping.

### 7. Events, projections, and notifications

A scheduling commit has one stable identity. Its privileged event records:

- command and operator identity, reason, authoritative time, and shortening intent;
- previous and resulting membership, deadlines, and extension policies;
- expected and resulting scheduling/unit revisions; and
- affected units and deterministic notification intent.

The public change projection contains only scheduling facts and the commit
identity: affected unit/group IDs, membership, deadlines, and relevant public
revisions. It excludes bidder identities, maximum bids, reserve values, and
operator-only reasons. Catalog visibility and access control remain host duties;
a scheduling projection is not authorization to expose an unpublished unit.

Each accepted manual scheduling change emits notification intent for affected
units, identifying whether deadlines shortened, extended, or membership changed.
The host resolves the authorized audience and delivers email, text, push, or
in-app notices. Automatic extensions retain the baseline event behavior; this
proposal does not require an email for every late bid. Delivery failures do not
roll back committed bidding state and require retryable operational handling.

State changes, their event batch, and notification intent must commit together.
A durable outbox is one possible implementation. Subscribers apply the scheduling
commit as a complete public change set or refetch at its revision; intermediate
per-member messages must not become contradictory authoritative group deadlines.
A lost response cannot cause a retry to duplicate events or notification intent.

### 8. Rejections and unchanged-state guarantee

Proposed rejection categories include stale revision/version, incomplete affected
set, duplicate membership, conflicting group definitions, invalid schedule/policy,
shortening not explicitly authorized, elapsed/closed unit, out-of-order time,
and unsupported capability. Closed codes are defined in the proposed contract
schema; rejection precedence and control-plane receipt retention are specified
in the service contract.

A rejected operation changes no unit, group, price, membership, deadline, event
history, or notification intent. Diagnostics may identify the affected public
unit or stale scheduling revision, but never disclose private bidding values.

## Alternatives

- **Freeze after the first bid:** simplest concurrency model, but prevents normal
  live editing and encourages replacement listings that fragment history.
- **Allow extensions only:** protects against accidental acceleration, but makes
  a genuinely necessary earlier deadline impossible without a workaround.
- **Let hosts rewrite deadlines directly:** flexible initially, but bypasses the
  canonical order, audit trail, replay, and cross-implementation conformance.
- **Implicit coordinator choice of a member deadline:** rejected. The host
  defaults initial group planning to the latest member deadline, but submits
  the resolved result explicitly; later edits remain deliberate commands.
- **Use a single auction-wide serialization stream:** straightforward and safe;
  may constrain throughput. It remains an implementation option, not a mandate.
- **Immediate forced close in the scheduling command:** flexible but combines
  rescheduling with irreversible outcome creation. This proposal separates them
  pending explicit policy and notification decisions.

## Conformance scenarios

[Draft review scenarios](proposals/flexible-live-scheduling-scenarios.md) define
synthetic inputs and observable outcomes for normal edits, shortening, stale
previews, partial group changes, ordering races, crash/retry, privacy, and close.
They are intentionally outside the executable accepted conformance suite.

They now have [26 machine-readable behavioral vectors covering 44 steps](proposals/flexible-live-scheduling/behavior-vectors.md),
including complete seeded unit states, exact expected resulting states, and
public/privileged record batches. Fixture checks replay the independent-unit
seed/bid/close portions and validate the proposed shapes. They do not execute a
coordinator. Passing current tests is not evidence of scheduling support.

## Privacy and security

Earlier deadlines can materially affect participants even when bids are sparse.
Treat shortening as a deliberate privileged operation, not as an ordinary catalog
side effect. Operators cannot use it to erase executed bids or disclose maxima.
Changing groups must not reveal private positions on another unit. A trusted
host's ability to operate the API does not authorize an arbitrary bidder to do so.

Preserve the complete retained audit trail rather than mutating old events.
Separate authorization, durable notification intent, and delivery evidence. Do
not claim that transactional commit guarantees every participant received notice.

## Compatibility

This is a future declared capability, not a permissive reinterpretation of
RFC 0001's `change_closing_time`. Baseline implementations continue rejecting
post-bid shortening and do not claim linked-group support. An unsupported host
must reject these operations, not decompose them into unsafe independent edits.

RFC acceptance requires maintainer agreement on the proposed capability,
schemas, behavioral vectors, and transaction contract before implementation of
new semantics. Advertising implementation support is a later gate: updated
specifications, every behavioral vector executed against the coordinator,
service transaction/failure coverage, and migration guidance. This separates
agreement on the contract from certification of code implementing it. Stable
units must retain compatible private state across topology revisions. No release
or production-readiness claim is made by publishing this proposed RFC.

## Unresolved questions

1. Review the proposed command/event names, capability identifier, and exact
   revision-vector schemas before treating them as a compatibility promise.
2. Review the selected auction-row transaction boundary, permanent receipt
   retention while mutable, and complete-commit replay contract.
3. Review the initial 4,096-unit / 4 MiB submission / 16 MiB batch ceilings and
   16-level parsing bound. These are proposed limits, not measured capacity.
4. Approve the behavioral vectors, then implement the coordinator and execute
   them plus the service concurrency/failure gates. Fixture and independent-unit
   checks do not satisfy coordinator conformance.

Immediate forced closing, post-close reopening, already-invoiced outcomes, and
correction workflows remain separate scope. Minimum notice lead time remains
host policy; this scheduling capability requires a strictly future deadline,
explicit shortening authorization, and durable notification intent.
