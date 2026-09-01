# Core concepts

Status: draft

## Deterministic decisions

The engine evaluates an explicit command against explicit state and
configuration. It emits zero or more events or a stable rejection. The
decision cannot depend on implicit wall-clock time, random values, network
responses, database reads, process identity, or host-language iteration order.

## Explicit ordering

Commands that affect the same bidding unit are evaluated in one authoritative
order. Transport receipt time alone is not a normative ordering rule. The
reference service will assign or verify ordering inside an atomic persistence
boundary.

## Optimistic concurrency

A state-changing command identifies the aggregate version it expects. A
command evaluated after that version has changed must not be silently applied
to different state.

## Idempotency

Repeating the same command identifier with the same payload returns the same
committed outcome. Reusing a command identifier with a different payload is an
error. Idempotency retention and archival behavior require an RFC before they
become normative.

## Events and replay

Accepted transitions emit immutable events. Applying the event stream in order
reconstructs authoritative state. Corrections are new authorized events, not
history mutation.

## Public and privileged facts

Event persistence does not imply public visibility. Private maximum bids and
other strategy-revealing facts require privileged audit access and must not
leak into public subscriptions, ordinary query projections, logs, or rejection
details.

## Money

Money is represented as an ISO 4217 currency code and integer minor units.
Floating-point amounts are forbidden at public boundaries.

## Deferred semantics

This draft does not decide pricing, increment, tie, reserve, extension,
opening, or closing rules. Those require accepted RFCs and conformance cases.
