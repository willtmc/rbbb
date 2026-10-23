# RFC 0001: Timed online proxy bidding baseline

> Specification 0.2.0: [accepted RFC 0005](0005-fixed-bid-ladder.md) supersedes
> the former short-increment and raw-maximum ranking rules. The current
> pricing sections below incorporate that decision; Git retains the 0.1.0 baseline.

- Status: accepted
- Author: Will McLemore
- Created: 2026-09-01
- Accepted: 2026-09-01
- Specification target: 0.2.0-draft

## Summary

RBBB's first auction format is timed online proxy bidding for independent lots.
A bidder authorizes a private maximum. The engine advances the public standing
amount only as far as required by the opening amount, competing maxima, reserve,
and configured increment schedule.

The format includes configurable increments, confidential reserves, per-lot
soft-close extensions, bidder withdrawal of unexecuted proxy authority,
audited operator bid removal, and constrained operator changes to closing time
and reserve.

This RFC does not cover outcry, quantity, choice, linked closing groups,
multi-parcel allocation or post-close reopening.

## Terminology

**Maximum** is the private highest amount a bidder currently authorizes.

**Executed amount** is the greatest amount to which that bidder's proxy has
already been used in an accepted standing-price decision.

**Standing amount** is the public current price.

**Next required amount** is the minimum maximum a challenger must submit.

**Leader** is the real bidder currently first in executable-maximum-and-priority order.
The reserve can affect price but can never be the leader or winner.

## Configuration

Each bidding unit has one currency, an opening amount, an optional confidential
reserve, an ordered increment schedule, an opening time, a closing time, and
optional extension settings. Opening and closing times are required; this RFC
does not define an untimed bidding unit.

Amounts are integer minor units. A bidding unit cannot mix currencies or
perform currency conversion.

Every amount is a non-negative integer no greater than 9,007,199,254,740,991
(2^53 − 1), the largest integer that is exact in all of JSON, IEEE 754 double
precision, and signed 64-bit integers. The bound applies to the opening
amount, the reserve, increment tier lower bounds and increments, every command
maximum, and every derived amount. A configuration outside the bound is
invalid; a bid or reduction maximum above it is rejected as `invalid_maximum`;
a reserve change above it is rejected as `invalid_reserve`. Derived amounts
never exceed the bound. At the last representable rung, the next required
amount saturates at that rung and further challengers are rejected. The numeric
bound is not an extra cut bid.

The same bound applies to every other integer in the contract: extension
trigger window and extension duration in seconds, expected and aggregate
versions, state versions, bidder priorities, and event indexes. A
configuration whose extension trigger window or extension duration exceeds
the bound is invalid.

Increment schedules are configurable. Each tier defines an inclusive lower
bound and a positive increment. The applicable tier is the tier with the
greatest lower bound not exceeding the amount being evaluated. Schedules must
have no gaps or overlaps across the permitted bidding range.

Example:

```yaml
increments:
  - from_minor_units: 0
    amount_minor_units: 1000
  - from_minor_units: 100000
    amount_minor_units: 2500
```

In USD, this means a $10 increment below $1,000 and a $25 increment beginning
at $1,000.

## Placing and pricing bids

Specification 0.2.0 uses the fixed tier-anchored ladder defined by
[RFC 0005](0005-fixed-bid-ladder.md) and the
[normative ladder contract](../specification/fixed-bid-ladder.md). All executed
amounts are ladder rungs. Arbitrary maximum entries remain accepted; cut bids
are not. The opening amount is the first executable rung. A first maximum
below opening is rejected; a new challenger must reach the next displayed rung.

Retain the entered maximum separately from its executable maximum: the highest
rung it authorizes. Rank by executable maximum, then its acceptance priority.
Remainder-only edits preserve priority. Moving to a different executable maximum
assigns new priority. Thus a higher raw remainder cannot win a tie.

With competition, price is the lesser of the leader's executable maximum and
the next rung above the runner-up's executable maximum, subject to opening,
reserve pressure and binding executed floors. There is no proxy clipping to
an off-ladder amount. The next required bid is the next rung above standing.

The current leader may increase private authority by any positive minor-unit
amount. Ordinary competitive standing price, next required amount and executed
floor remain unchanged. A later accepted challenger is priced normally. The
only price-changing exception is unmet reserve pressure below. Remainder-only
edits by any existing bidder are private and do not change price or closing.

Accepted odd maxima and reductions carry a private, nonblocking bidder notice
showing their highest executable amount and the next rung. No automatic upward
rounding or extra confirmation is allowed; see RFC 0005's response contract.

## Confidential reserve

Reserve is a threshold, never a bidder or winner. Off-ladder reserve pressure
uses the first rung at or above the reserve, capped by executable authority.
Reserve is met only when the executable maximum reaches the raw reserve. If no
representable rung can reach reserve, reserve remains unmet. For example, a
$134 reserve on a $10 ladder requires $140; a $139 maximum executes only $130
and remains below reserve. Lowering reserve never unwinds an executed price.

The public contract exposes only reserve status, never the raw reserve.
Confidential does not mean undiscoverable: public price and reserve status can
bound the reserve. A unit closing below reserve produces no_sale.

## Reducing an unexecuted proxy

While bidding remains open, a bidder may reduce their maximum to any amount at
or above their executed amount. They cannot withdraw an amount already
executed by the proxy.

Cancelling or revoking a maximum has the same bidder permissions as reducing it:
only unused future proxy authority may be withdrawn. Executed competitive bids
remain binding, including the current leader's executed bid. A bidder MUST NOT
use revocation, a zero maximum, or an operator-command-shaped request to remove
an executed commitment. For example, a $160 maximum that has executed $150
against a $142 entered maximum (executable to $140 on a $10 ladder) can be
reduced to $150, but not $140 or zero.

A reduction is evaluated in authoritative command order. If intervening
competition executes more of the proxy first, the executed floor rises and a
now-invalid reduction is rejected.

That rejection reports the bidder's own executed floor as
`executed_floor_minor_units` so the bidder can resubmit a valid reduction. The
field is bidder-own data: the executed amount belongs to the bidder whose proxy
was used, and a host returns it only to that bidder over the command channel.
When a sole bidder's proxy has executed up to reserve pressure the floor equals
the executed ladder amount at or above reserve, but that amount is already the bidder's public
standing amount. The field never reveals another bidder's maximum, an
unexecuted reserve, or any identity.

A reduction to a different executable maximum uses executable-maximum priority:
its new rung follows an earlier equal rung. A remainder-only reduction retains
the original priority. This can
change the leader at the unchanged standing amount; it must not discard the
executed floor or create a new competitive price. That leader change is public
and follows the existing extension policy.

An accepted reduction is privately audited. When it changes no public result,
it emits no public price event and does not trigger a closing extension.

## Timed closing and extensions

The service assigns authoritative time and order at the bidding unit's command
ordering boundary. Client clocks and client-supplied timestamps do not decide
eligibility or priority. Authoritative timestamps carry an explicit UTC offset;
a zone-less timestamp is invalid rather than interpreted in host-local time.

Authoritative timestamps carry at most millisecond precision. A timestamp with
more than three fractional digits is invalid rather than truncated, so an
implementation whose native time type is millisecond-based can replay every
command stream and compute every extended closing time exactly. The canonical
serialized form is UTC with a `Z` designator; the fractional part is omitted
when zero and otherwise trimmed of trailing zeros, for example
`2026-09-01T13:00:00Z`, `2026-09-01T13:00:00.25Z`, and
`2026-09-01T13:00:00.001Z`.

Authoritative time is monotone across the accepted command sequence. A command
whose authoritative time is earlier than the last accepted command's time is
rejected as `effective_at_out_of_order`; an equal time is permitted.

A bid or reduction ordered before the opening time is rejected as
`bidding_not_open`. A bid ordered at or after opening and strictly before the
current closing time is eligible. A bid ordered exactly at or after closing
time is rejected as closed. A bid ordered before closing remains eligible if
its transaction commits afterward. Operator reserve and schedule changes remain
permitted before opening time.

Extension trigger window and extension duration are configurable. A qualifying
bid resets closing time to the authoritative bid time plus the configured
extension duration; it does not add the duration to the prior closing time. An
extension can only move closing later: when bid time plus duration would fall
before the current closing time, closing time is unchanged and no
`closing_time_changed` event is emitted.

A qualifying bid is an accepted command that changes the public standing amount
or leader. Increasing one's own private maximum without changing the public
result does not extend closing.

Example: with a 1:00 PM close, five-minute trigger window, and five-minute
extension, a qualifying bid at 12:58 resets close to 1:03. Another at 1:02
resets it to 1:07.

## Operator bid removal

Bidders cannot erase accepted bids. Before closing, an authorized operator may
void a bid using a command that includes operator identity, reason, and
notification policy.

The host MUST authenticate the actor and authorize operator correction separately
from bidder access before invoking the pure engine. An `operator_id` supplied by
a caller is not authorization. The actor must be server-bound; the correction
must record the target, actual reason, authoritative time and notification
policy. A bidder's cancellation request MUST NOT be promoted into this operation.

A maximum revocation does not mean its original authorization was invalid from
the beginning. In particular, removing one generated execution while preserving
earlier executed bids is not a full authorization void. Importers MUST NOT infer
such a void from a maximum-row deletion or manufacture an operator reason.
If the source does not identify an authorized correction with sufficient scope
and audit evidence, report it as unsupported/unassessed. Selective execution
correction is not specified by this full-authorization void operation.

Voiding emits a new immutable audit event; it does not delete the original bid.
The engine recomputes standing amount, leader, reserve status, and next required
amount from remaining valid bids in authoritative order, applying the same
leader-increase exception as live bidding. It MUST NOT reconstruct price solely
from final maxima or introduce a new price movement at the end of replay. It also recomputes each remaining bidder's
executed amount from those bids. A voided competing bid cannot continue to bind
another bidder's proxy-withdrawal floor.

Notification policy is one of:

- `affected`: removed bidder plus bidders whose leading status changes;
- `removed_bidder`: removed bidder only;
- `all_bidders`: every bidder on the bidding unit; or
- `none`: permitted only with a recorded reason.

The engine emits notification intent and deterministic state-change events. The
host platform sends email, SMS, or push notifications. Delivery failure does
not roll back removal and must be handled as a separate retryable operational
failure.

Post-close bid correction is outside v0.1.

## Operator schedule and reserve changes

Before the first accepted bid, an authorized operator may move closing time
earlier or later. After bidding begins, closing may be extended but not
shortened. Closed bidding units cannot be reopened in v0.1.

Before the first accepted bid, an operator may set, raise, lower, or remove
reserve. After bidding begins, reserve may only be lowered or removed. A lower
reserve immediately recomputes reserve status but never reduces an already
executed standing amount or bidder executed floor. It withdraws only
unexecuted future reserve pressure. This is expected to be an exceptional
operator action, but its outcome remains deterministic and audited.

Every operator change records actor, reason, previous value, and new value.
Reserve values remain privileged; public output contains only resulting public
price and reserve-status changes.

## Events and privacy

Privileged audit events contain the accepted maximum, executed amount, operator
identity, reasons, and reserve changes needed for deterministic replay.

Public events contain only authorized observable facts such as standing amount,
next required amount, leader change, reserve status, closing time, and final
sale status. They never expose a private maximum, confidential reserve, account
identity, or operator-only reason.

Public bidder presentation belongs entirely to the host platform. RBBB does
not standardize or emit a public bidder, leader, or winner identifier. A host
may display an anonymous paddle number, username, initials, or no identity at
all without changing engine conformance.

Bidder-facing notifications may identify that bidder's own maximum and removal
details through a separately authorized host-platform view.

Exact idempotency and audit-retention periods belong to the reference-service
contract, not the auction-behavior algorithm. Commands retain stable IDs and
events remain immutable and ordered. A host must publish its retention policy;
records may move to archival storage but cannot be selectively rewritten while
retained.

## Closing result

At closing, a bidding unit with no accepted real bid produces `no_bid`. A unit
with a leader below reserve produces `no_sale`. A unit with reserve met or no
reserve produces `sold` with the leader and standing amount as the winning
result.

Closing is represented by an explicit, ordered engine command rather than an
implicit wall-clock mutation. A qualifying bid already ordered before the
close command is evaluated first and may extend closing; later bids are
rejected.

## Amendments

- 2026-10-22: maintainer reaffirmed that bidders may cancel only unused maximum
  authority. Executed bids require separately authorized, audited operator
  correction; row removals must not be silently promoted to full authorization
  voids. Added host admission/floor/audit/post-close regressions.

- 2026-10-22: maintainer-accepted clarification that a leader's maximum increase
  preserves competitive standing price, next required amount and executed floor,
  with only existing reserve pressure allowed to advance the price. Ordered void
  reconstruction follows the same rule. Clarified exact-maximum tie priority when
  reducing back to an executed floor. Covered by scenarios 031–036 and the
  synthetic shared-closing-clock leader-maximum vector.

- 2026-09-01: clarified that extensions never shorten closing, that bids
  before opening time are rejected, that authoritative time is monotone across
  accepted commands, and that timestamps require an explicit offset. Backed by
  conformance scenarios 027–029.
- 2026-09-01: clarified that opening and closing times are required
  configuration; an untimed bidding unit is outside this RFC.
- 2026-09-01: bounded every amount at 2^53 − 1 with saturation of the next
  required amount, and fixed authoritative timestamp precision at one
  millisecond with a canonical serialized form, so independent implementations
  in double-precision or 64-bit-integer languages reach identical outcomes.
  Backed by conformance scenario 030.
- 2026-09-01: extended the 2^53 − 1 bound from amounts to extension seconds,
  versions, priorities, and event indexes, and declared a configuration with
  extension seconds above the bound invalid. Backed by the shared integer
  schema and the specification document validator.

## Alternatives considered

### Require all maxima to land on increment boundaries

Rejected for both 0.1 and 0.2 as an input restriction. Since accepted RFC 0005,
execution follows the ladder even though authorization may end between rungs.
The short increments of 0.1 are no longer permitted.

### Add the extension duration to the previous close

Rejected. Resetting close to bid time plus duration gives every bidder the
configured response window without accumulating excess time.

### Allow bidders to lower any private maximum

Rejected. Only unexecuted proxy authority can be withdrawn; executed bids
remain binding and auditable.

### Treat reserve as a bidder that wins ties

Rejected. A real bidder meeting reserve satisfies the seller threshold and
must prevail over the reserve.

## Deferred capabilities

- linked extension groups;
- post-close reopening and correction;
- bidder self-service notification preferences;
- quantity, choice, multi-parcel, outcry, and hybrid auctions; and
- cross-bidding-unit exposure limits.
