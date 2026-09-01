# RBBB specification

The specification is the language-neutral source of truth for compatible
auction behavior. It is currently a **draft** and has no stable compatibility
guarantee. RFC 0001 schemas are marked `experimental`: complete enough for
implementation review, but still eligible for incompatible correction before
the first stable release.

## Normative sources

Normative requirements live in:

- prose under this directory;
- JSON Schemas for configuration, commands, events, and state;
- the HTTP contract in `openapi.yaml`;
- the subscription contract in `asyncapi.yaml`; and
- observable examples under `../conformance/`.

If two normative sources conflict, that is a specification defect. Do not
silently choose one; open an issue and add a conformance case with the fix.

## Stability markers

Documents and schemas may carry one of these statuses:

- `draft`: exploratory and subject to incompatible change;
- `experimental`: implementable but not yet a compatibility promise;
- `stable`: governed by semantic versioning and migration requirements.

Unmarked documents remain `draft` until explicitly stated otherwise.

RFC 0001 contract schemas use the `experimental` marker described above. See
[`contract.md`](contract.md) for envelope, amount, visibility, and state-view
conventions.

## Design requirements

A compatible design must be deterministic for the same ordered inputs,
idempotent for repeated command IDs, replayable from immutable events,
explicit about aggregate versions, and careful not to disclose private bidding
facts through public contracts.

## Versioning

The current draft version is recorded in `VERSION`. Implementations will claim
specific specification and conformance-suite versions rather than claiming
compatibility with an unqualified project name.
