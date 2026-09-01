# RBBB specification

The specification is the language-neutral source of truth for compatible
auction behavior. It is currently a **draft** and has no stable compatibility
guarantee.

## Normative sources

Once the first RFC is accepted, normative requirements will live in:

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

Everything is `draft` until explicitly stated otherwise.

## Design requirements

A compatible design must be deterministic for the same ordered inputs,
idempotent for repeated command IDs, replayable from immutable events,
explicit about aggregate versions, and careful not to disclose private bidding
facts through public contracts.

## Versioning

The current draft version is recorded in `VERSION`. Implementations will claim
specific specification and conformance-suite versions rather than claiming
compatibility with an unqualified project name.
