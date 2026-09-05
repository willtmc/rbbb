# Flexible live scheduling: proposed conformance scenarios

These are **draft review scenarios**, not accepted conformance requirements or
executable certification. They accompany the [proposed RFC](../flexible-live-scheduling.md).
All identifiers, dates, and situations below are invented. No real auction data
or proprietary payloads are used.

The command/event names are provisional. Before acceptance, expand each scenario
into exact schema-validated configurations, commands, event batches, rejections,
and final public/privileged state expectations. Existing valid bid states are
represented here as `S_A`, `S_B`, and `S_C`; those symbols must be replaced with
fully reproducible synthetic bid sequences in executable scenarios.

## Common review setup

- Units `unit-a`, `unit-b`, `unit-c` have stable, distinct identities and
  independent proxy/pricing state.
- Opening time is `2031-04-17T10:00:00Z`.
- Unless stated otherwise, authoritative time is `2031-04-17T12:00:00Z` and
  every affected unit's deadline is `2031-04-17T15:00:00Z`.
- A shared extension policy has a 120-second trigger window and 180-second
  duration. Explicit resulting policies are included with topology changes.
- Expected revisions refer to the actual current scheduling/unit revisions
  unless a scenario deliberately makes them stale.
- Actor `operator-demo` is authorized by the host, except in the unauthorized
  case. Reasons are privileged, not public strings.
- A successful manual change emits exactly one logical scheduling commit and
  one deduplicatable notification intent for that command. Its complete public
  change set and privileged audit data are separate projections.
- All scheduling-only changes leave prices, maxima, executed floors, bidder
  priorities, accepted-bid history, and reserve state unchanged.

## FLS-01 — Add a unit after other units have bids

**Given:** `unit-a` and `unit-b` have valid bid states `S_A` and `S_B`.

**When:** the host creates `unit-c` with empty state and explicitly attaches it
to their closing group, accounting for all three units at the current versions.

**Then:** all three share the requested deadline/policy. `S_A` and `S_B` remain
unchanged; `unit-c` has no inherited bidder or standing amount. A later bid on
`unit-c` affects only its price/positions, with any qualifying extension shared
by the group. A stale attachment fails without modifying the existing group;
a newly created ungrouped unit is not exposed as attached by that failed command.

## FLS-02 — Reorder presentation without rescheduling

**Given:** a host displays units in order A, B, C.

**When:** it changes presentation to C, A, B without a scheduling command.

**Then:** RBBB state, group membership, deadlines, and revisions do not change.
The host cannot claim the display edit also moved closing times.

## FLS-03 — Merge groups with existing bids

**Given:** A and B belong to `group-left`, closing at 15:00; C belongs to
`group-right`, closing at 15:20. Each has independent valid bid state.

**When:** one operation explicitly places A, B, C in `group-joined`, closing at
15:25 with the specified shared policy, and retires the two source groups.

**Then:** all membership/deadline changes commit together. No bidder positions
are combined. Both source groups are retired in the audit history; unrelated
units and groups retain their revisions.

## FLS-04 — Split a group and leave a unit ungrouped

**Given:** A, B, C share `group-original` at 15:00 and have bids.

**When:** a complete replacement puts A and B in `group-pair` at 15:10 and
leaves C ungrouped at 15:15 with its explicit standalone extension policy.

**Then:** the original group is retired. A qualifying later bid on C cannot
extend A or B. A qualifying bid on A extends A and B but not C.

## FLS-05 — Deliberately shorten after bids exist

**Given:** A has state `S_A`, deadline 15:00, and an inspected current revision.

**When:** at 12:00 an authorized operation explicitly allows shortening and
requests 14:30, supplying the expected revisions and a privileged reason.

**Then:** the deadline becomes 14:30, `S_A` remains intact, and the public change
set states the new deadline without leaking the reason or bidder identities.
The privileged audit retains 15:00 → 14:30 and the actor. Notification intent
identifies A and the shortening. A later bid at 14:30 is ineligible.

## FLS-06 — Shortening omitted from an otherwise valid edit

**Given:** A closes at 15:00; B closes at 15:20; both have bids.

**When:** an operation groups them at 15:10 but does not explicitly allow
shortening B.

**Then:** reject the whole operation. Do not extend A first, change membership,
or emit notification intent for a partial result. Choosing a deadline between
the two existing times is not treated as an extension-only operation.

## FLS-07 — Past or immediate deadline is not ordinary rescheduling

**Given:** authoritative time is 12:00 and the unit closes at 15:00.

**When:** a schedule operation requests 11:59:59.999 or exactly 12:00, even with
shortening permission.

**Then:** reject with unchanged state. A deadline of 12:00:00.001 is a strictly
future candidate under this proposal, subject to all other guards. The policy
question of a minimum notice interval remains explicitly open in the RFC.

## FLS-08 — A delayed close worker does not authorize resurrection

**Given:** A's deadline is 12:00, but no terminal close command has committed.

**When:** at 12:00:00.001 an operator attempts to extend A to 15:00 or attach it
to an open group.

**Then:** reject as elapsed. The same operation against an already terminal A
also rejects. Reopening requires its own separately accepted operation.

## FLS-09 — A qualifying bid orders before regrouping

**Given:** A and B share a 15:00 deadline. An operator preview was taken before
a qualifying bid on A at 14:59:30.

**When:** the bid orders first, extending both to 15:02:30; the old preview's
regrouping command orders afterward.

**Then:** the bid and shared extension remain accepted. Reject the stale edit;
do not overwrite the extension with its old inspected schedule. A new edit
requires fresh versions and an explicit acknowledgment if it would shorten the
now-later deadline. The engine does not silently retry stale operator intent.

## FLS-10 — Regrouping orders before a bid

**Given:** A and B are grouped; C is separate. At 14:59, a complete change first
moves A and C into a group closing at 15:10 and leaves B separate at 15:00.

**When:** a later qualifying bid on A at 15:09 orders under the new topology.

**Then:** A and C extend to 15:12; B is unaffected. A bid on B ordered exactly
at 15:00 rejects. No old-group routing survives the scheduling revision.

## FLS-11 — Equal timestamps still have an order

**Given:** a bid and a scheduling command both have effective time 14:59:30.125.

**When:** run one sequence with the bid first and another with the edit first.

**Then:** each sequence produces its respective deterministic outcome under
FLS-09/FLS-10. Identical client timestamps, thread scheduling, or packet arrival
at a non-authoritative edge do not substitute for the authoritative sequence.

## FLS-12 — A private-only maximum increase does not extend the group

**Given:** A and B share a 15:00 deadline; A's current leader can increase their
maximum without changing public price or leadership.

**When:** that accepted increase orders at 14:59.

**Then:** the maximum change is privately audited. Neither A nor B extends, and
no new public price event or scheduling-change notice is invented. A concurrent
operator preview can still become stale because accepted state changed.

## FLS-13 — Missing or duplicate membership is not a partial edit

**Given:** `group-left` contains A and B; `group-right` contains C.

**When:** a merge request omits B, or assigns A to two resulting groups.

**Then:** reject with unchanged topology, deadlines, bid states, and revisions.
Silently treating an omitted member as ungrouped is not permitted.

## FLS-14 — Crash after commit, before acknowledgment

**Given:** a valid regrouping command commits, including audit/public events and
notification intent, but its response is lost.

**When:** the caller retries the identical command ID and content.

**Then:** return the original receipt; no new topology revision, events, or
notification intent. A retry with different content under that ID rejects.
A crash before commit leaves no partial unit/group update. Event consumers may
receive a batch again but must not apply a half-batch as authoritative state.

## FLS-15 — Authorization and privacy are separate from supplied flags

**Given:** an untrusted caller supplies `operator-demo`, a reason, and
`allow_shortening` without the required host authorization.

**When:** it requests a shorter deadline.

**Then:** the service rejects before mutation. Neither success nor rejection
payloads expose maxima, bidder identities, reserve values, or operator reasons.
A reason string or a boolean is never proof of authority.

## FLS-16 — Close races with a group edit

**Given:** A and B share a 15:00 deadline and retain independent prices.

**When:** the ordered group-close command at 15:00 commits before a later edit.

**Then:** both units get their independent terminal results atomically; the
later edit rejects. If a qualifying bid ordered before 15:00 extended the group,
a close attempt at the old deadline instead rejects as too early. No member is
closed against an obsolete topology or revived by an edit.

## FLS-17 — Rejected compound edit has no monetary or partial side effects

**Given:** a multi-group edit includes one invalid policy or stale unit version.

**When:** all other groups would otherwise validate.

**Then:** none changes. There are no partial schedule events, notifications,
recomputed prices, altered executed floors, or terminal results. Validation must
not publish a successful subset.

## FLS-18 — Joining different policies requires an explicit result

**Given:** A uses a two-minute trigger window; B uses a five-minute window.

**When:** they are grouped without an explicit resulting extension policy.

**Then:** reject. When the request explicitly chooses a valid common policy,
all subsequent group extensions use it. The former policy of whichever member
happened to be listed first never wins implicitly.
