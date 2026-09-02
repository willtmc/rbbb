# RFC 0001: Timed online proxy bidding baseline

- Status: accepted
- Author: Will McLemore
- Created: 2026-09-01
- Accepted: 2026-09-01
- Specification target: 0.1.0-draft

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
multi-parcel allocation, post-close reopening, or forced realignment after a
short increment.

## Terminology

**Maximum** is the private highest amount a bidder currently authorizes.

**Executed amount** is the greatest amount to which that bidder's proxy has
already been used in an accepted standing-price decision.

**Standing amount** is the public current price.

**Next required amount** is the minimum maximum a challenger must submit.

**Leader** is the real bidder currently first in maximum-and-priority order.
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
never exceed the bound: when the standing amount plus its increment would
exceed it, the next required amount is the bound itself. That saturated case
is the only one in which the next required amount equals the standing amount.

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

The first maximum must be at least the opening amount. A first maximum below
opening is rejected. A first maximum at or above opening establishes the
standing amount at opening unless reserve pressure requires more.

A challenger's maximum must be at least the displayed next required amount.
The current leader may increase their private maximum by any positive amount,
even when the increase is smaller than a full increment, because doing so does
not change the public result.

Among real bidders, the greatest maximum leads. Equal maxima are ordered by the
authoritative sequence in which those exact maxima were accepted; the earlier
maximum retains priority.

Without reserve pressure, competition establishes:

```text
competitive amount = min(
  leader maximum,
  runner-up maximum + increment_for(runner-up maximum)
)
```

The increment tier is selected using the losing maximum, not the prior standing
amount. The standing amount cannot exceed the leader's maximum. Consequently,
a maximum may produce a short increment. For example, if the losing maximum is
$1,000, its applicable increment is $25, and the leader's maximum is $1,001,
the standing amount is $1,001 rather than $1,025.

The next required amount is:

```text
standing amount + increment_for(standing amount)
```

After the $1,001 short-increment example, the next required amount is $1,026
when the $25 tier applies at $1,001.

## Confidential reserve

The reserve behaves like a synthetic proxy threshold for pricing, except that
it can never lead or win and loses every tie to a real bidder.

Reserve pressure contributes:

```text
reserve amount applied = min(leader maximum, configured reserve)
```

The public standing amount is the greatest amount required by opening,
competition, and reserve pressure, capped at the leader's maximum.

A maximum equal to reserve meets reserve. A maximum below reserve may lead at
its full maximum while the public status remains `reserve_not_met`. A maximum
above reserve raises the standing amount to at least reserve and makes the
public status `reserve_met`.

The public contract exposes only reserve status, never the reserve amount.
Confidential means unpublished, not undiscoverable: because reserve pressure
stops the standing amount exactly at the reserve, a bidder whose maximum
exceeds it, and any observer once status becomes `reserve_met`, can infer the
amount from the public price. A bidding unit that closes below reserve
produces `no_sale`, not a winner.

## Reducing an unexecuted proxy

While bidding remains open, a bidder may reduce their maximum to any amount at
or above their executed amount. They cannot withdraw an amount already
executed by the proxy.

A reduction is evaluated in authoritative command order. If intervening
competition executes more of the proxy first, the executed floor rises and a
now-invalid reduction is rejected.

That rejection reports the bidder's own executed floor as
`executed_floor_minor_units` so the bidder can resubmit a valid reduction. The
field is bidder-own data: the executed amount belongs to the bidder whose proxy
was used, and a host returns it only to that bidder over the command channel.
When a sole bidder's proxy has executed up to reserve pressure the floor equals
the confidential reserve, but that amount is already the bidder's public
standing amount. The field never reveals another bidder's maximum, an
unexecuted reserve, or any identity.

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

Voiding emits a new immutable audit event; it does not delete the original bid.
The engine recomputes standing amount, leader, reserve status, and next required
amount from remaining valid bids. It also recomputes each remaining bidder's
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

Rejected for v0.1. Bidders may authorize any positive minor-unit amount that
meets the next required amount. Proxy clipping can therefore produce a short
increment.

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

- optional forced realignment to regular increments after proxy clipping;
- linked extension groups;
- post-close reopening and correction;
- bidder self-service notification preferences;
- quantity, choice, multi-parcel, outcry, and hybrid auctions; and
- cross-bidding-unit exposure limits.
