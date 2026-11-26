# RFC 0005: Fixed bid ladder with arbitrary maximum authority

- Status: Accepted
- Accepted by maintainer: 2026-10-23
- Specification: 0.2.0-draft (incompatible with 0.1.0-draft)

## Decision

All executed bids follow a fixed published ladder; there are no cut bids.
A bidder may enter any otherwise-valid maximum. Retain that exact authorization,
but use only its highest executable rung for competition, reserve satisfaction,
executed floors and tie priority. Unused remainder has no competitive effect.
This supersedes RFC 0001's short-increment pricing and raw-maximum tie rules.
The leader's own increase still does not reprice ordinary competition.

## Ladder definition

Each configured tier begins at an inclusive monetary breakpoint B and defines
step D. Its rungs are B + n*D, for nonnegative integers n, below the next
breakpoint. Every breakpoint is itself a rung. Thus a tier boundary is fixed
in advance, even when the preceding step does not divide its interval exactly.
The configured opening amount is also a rung; amounts below opening cannot be
executed. Above opening, use the tier rungs, never an offset derived from a bid.
Amounts and arithmetic remain bounded by the interoperable money limit.
Find rungs by integer arithmetic per tier, not iteration through individual bids.

For example, tiers at 0/$1, $10/$2, $25/$5, $100/$10, $250/$25 produce
$22, $24, $25, $30 and $240, $250, $275. An odd opening of $23 starts at
$23, then $24, $25, $30. Opening and tiers are immutable for a bidding unit.

Let E(M) be the greatest rung at or below entered maximum M (zero when no
executable rung exists). Reject a first bid below opening as before. A new
challenger must authorize at least the next rung above the standing price.
Rank positions by E(M), then the authoritative acceptance order of that
executable maximum. Edits within the same rung preserve priority; an increase
or reduction to another rung acquires new priority. History still records each
command's actual sequence, independently of retained position priority.

With competition, price is min(leader executable maximum, next rung above
runner-up executable maximum), subject to opening, reserve pressure, and binding
executed floors. Equal executable maxima retain earlier priority at that rung.
A losing position executes only its executable maximum, never its remainder.
A private leader increase does not reprice existing competition. Later accepted
competition uses the formula normally. At the last representable rung, next
required saturates to that rung and further challengers are rejected; no cut bid
is fabricated at the numeric ceiling.

## Reserves, reductions, corrections and clocks

An off-ladder confidential reserve requires the first rung at or above reserve.
Reserve pressure is capped by the leader's executable maximum. Reserve is met
only when that executable maximum reaches the raw reserve. If no representable
rung can reach reserve it remains unmet. Lowering reserve does not unwind an
executed price. Reductions cannot cross executed floors; unused remainder can
be cancelled. Operator voids replay the same ladder and priority rules from
retained authorization history. Existing operator audit requirements and the
post-close correction boundary do not change. Closing and extension rules do
not change; remainder-only edits do not change the public result.

## Bidder notice

A successful odd maximum or reduction returns a private `maximum_not_fully_executable`
notice with currency, entered maximum, executable maximum, next ladder amount
(or null at the ceiling), and readable text. It is nonblocking: no extra
confirmation and no automatic upward rounding. Hosts show it only to the
submitting bidder or authorized operator, never in public auction events.
Example: "Your maximum of USD 249.00 is accepted. Under this item's bid
increments, we can bid up to USD 240.00 for you. The next available amount is
USD 250.00." A host may offer a separate explicit action to increase authority.
The notice is retained in the privileged command event so retries and replay
return the same information. It must not disclose another bidder's maximum.

## Compatibility and validation

The old 0.1.0 specification, engine commit and historical captures remain pinned;
never restore their states into 0.2.0 or silently migrate live auctions. Start new
units under the new version. Historical comparisons with changed tier boundaries
are counterfactual experiments, not parity failures or predicted bidder behavior.
Conformance covers tier boundaries, odd maxima, ties, remainder-only edits,
reserve rounding, reductions, void replay, numeric bounds and private notices.
