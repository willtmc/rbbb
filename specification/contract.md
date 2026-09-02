# RFC 0001 contract conventions

Status: experimental

This document explains how the language-neutral schemas relate to RFC 0001,
the conformance suite, and the pure Ruby reference engine. The schemas are
complete enough for implementation and interoperability review, but they are
not yet a stable compatibility promise.

## Amounts and currency

A bidding unit has exactly one configured ISO 4217 currency. Every amount in
its commands, events, and state is therefore an integer field ending in
`_minor_units`. Floating-point values and currency conversion are forbidden.

The currency appears once in configuration and query state. Repeating a money
object on every command would add a second source of truth and create a
currency-mismatch failure mode without adding information.

## Service envelope and core inputs

Files under `commands/` define the external service envelope. Every command
has stable routing identifiers, `expected_version`, and authoritative
`effective_at`. `bid_id` is also explicit for a placed bid so later correction
can address one immutable bid without relying on a generated identifier.

Conformance scenarios intentionally abbreviate this envelope. A fixture fixes
the auction configuration and one synthetic bidding unit, command order
supplies the expected aggregate version, and older scenarios use `command_id`
as the deterministic fallback `bid_id`. Implementations must not interpret
those omissions as permission for a network service to rely on client clocks,
implicit routing, or random identifiers inside its decision function.

The pure Ruby engine consumes the abbreviated core form directly. A reference
service adapter will validate the full envelope, resolve the aggregate, assign
authoritative order and time, and then call the pure decision boundary.

## Events and visibility

Every committed service event uses the common envelope in
`events/base.schema.json`. Public and privileged payloads are separate schema
unions:

- `events/public-event.schema.json` contains only observable price, reserve
  status, schedule, and closing-result facts;
- `events/privileged-event.schema.json` contains the identities, maxima,
  reserve values, operator reasons, notification intent, and resulting state
  needed for audit and replay.

The public schema must never acquire a bidder, leader, or winner identifier; a
private maximum; a reserve amount; or an operator-only reason. A host may map
its own authorized anonymous bidder presentation outside this contract.

The ordinary HTTP command result returns only `public_events`. A committed
command may return an empty public-event array when it changes only private
authority. The privileged event union is for an authenticated audit and
persistence boundary; this draft intentionally does not expose that boundary
as an HTTP endpoint.

Ordinary rejection responses contain the command identifier, a stable reason
code, and at most the finite, reason-specific fields that
`rejections/rejection.schema.json` declares. This experimental contract
intentionally omits an open-ended details object: an arbitrary object would
make accidental disclosure of a maximum, reserve, or identity too easy. Every
additional field must be declared on the schema, gated to exactly one reason,
and limited to data the rejected command's own author is already entitled to
know. `scripts/validate_documents.rb` enforces that structure and that
conformance scenarios assert no undeclared rejection keys.

The only such field today is `executed_floor_minor_units`, which accompanies
`maximum_below_executed_amount`. It reports the rejected bidder's own executed
amount, the lowest maximum that bidder may still authorize, so the bidder can
submit a valid reduction without a privileged query. It is bidder-own data:
while that bidder leads it equals the public standing amount, and otherwise it
equals the bidder's own fully executed maximum. When a sole bidder's proxy has
executed up to reserve pressure the value coincides with the confidential
reserve, but the bidder already observes that amount as the public standing
amount. A host must return the field only to the bidder who issued the
rejected command and must never place it in a public projection.

All events emitted by one accepted command share its resulting
`aggregate_version`. `event_index` gives their deterministic zero-based order;
consumers must not infer order from timestamps or identifier collation.

## State views

`state/bidding-unit.schema.json` is the public query projection. It deliberately
cannot answer who is leading or what any bidder authorized.

`state/aggregate.schema.json` is privileged replay state. It contains current
positions and the immutable authorization, reserve-change, and bid-void facts
needed by a compliant implementation. Possession of aggregate state does not
authorize public disclosure.

## Invariants beyond JSON Schema

JSON Schema validates shape and local value constraints. RFC prose,
conformance scenarios, and engine checks remain normative for relational and
ordered invariants, including:

- opening time precedes current closing time;
- authoritative times never regress across accepted commands, and every
  timestamp carries an explicit UTC offset;
- an extension never moves closing time earlier;
- increment tiers are ordered and cover the permitted range;
- executed amount never exceeds its maximum;
- priorities are unique and ordered;
- reserve-change history is continuous;
- terminal result agrees with leader and reserve state; and
- applying an event advances exactly one aggregate version.

The reference service must enforce these invariants transactionally rather
than assuming shape validation is sufficient.
