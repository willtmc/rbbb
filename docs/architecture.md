# Architecture

This document records the intended boundaries of RBBB. It is informative until
individual requirements are accepted into the specification.

## Core model

The engine is a deterministic state machine:

```text
(current state, configuration, command) -> decision
(current state, accepted events)        -> new state
```

Given the same initial state, configuration, ordered commands, and engine
version, a conforming implementation must produce the same observable result.
Wall-clock reads, random values, database queries, and network calls therefore
do not belong inside the decision function. Required time and identifiers are
explicit inputs.

## Layers

### Specification

Defines commands, events, state, configuration, rejection reasons, ordering,
and invariants without reference to an implementation language.

### Conformance suite

Expresses policy decisions as portable input/output scenarios. A conforming
implementation must pass every scenario for the claimed specification version.

### Pure Ruby engine

Implements the state transition rules without Rails, persistence, or network
dependencies. It should be embeddable and replayable.

### Reference service

Will provide persistence, serialization, authentication boundaries,
transactions, idempotency, command ordering, HTTP queries and commands,
subscriptions, health, metrics, and audit access around the pure core.

## Serialization boundary

Commands that can affect the same bidding outcome require one authoritative
order. The initial aggregate is a bidding unit: normally one lot, or a linked
group when an accepted rule makes the group share a closing or allocation
decision. Horizontal application concurrency does not remove this ordering
requirement.

Commands carry an expected aggregate version. A service either commits the
resulting events atomically at that version or rejects the stale command for a
safe retry.

## Ownership boundary

The engine owns:

- bidding-unit lifecycle and bid state;
- validation, ordering, pricing, increments, ties, reserves, and extensions;
- winning-position calculations and stable rejection reasons;
- authorized overrides that alter bid state; and
- the immutable bid-state audit history.

The host platform owns:

- accounts, identity, registration, and eligibility decisions;
- catalog descriptions and media;
- credit cards, deposits, payments, invoices, and tax;
- marketing, email, text messages, and push notifications;
- fulfillment, removal, CRM, seller management, and settlement.

The host tells the engine which bidder is authorized and under what explicit
constraints. The engine does not need to know how that decision was made.

## Privacy boundary

Maximum bids and other strategy-revealing facts are private inputs. Public
events and query projections must expose only information authorized by the
specification. Audit access to private facts is a separate privileged surface.

## Extensibility

Auction variation is expressed through a finite vocabulary of specified,
composable configuration—not arbitrary callbacks. A genuinely new auction form
requires an RFC, schemas, conformance scenarios, and implementation support.

## Accepted and deferred behavior

RFC 0001 accepts normative rules for timed online proxy bidding, including
opening amounts, equal maxima, increment boundaries, reserves, extension
timing, proxy reduction, and constrained operator actions. Quantity, choice,
linked closing groups, multi-parcel allocation, outcry, and hybrid auctions
remain deferred and must not be inferred from another auction system.
