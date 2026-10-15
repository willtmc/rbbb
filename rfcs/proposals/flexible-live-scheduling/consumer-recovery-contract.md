# Authorized consumer recovery — proposed adapter contract

Status: **DRAFT / NOT ACCEPTED / NOT IMPLEMENTED**. This document proposes
embedding protocol details under service-contract §6. It changes no accepted
schema, event semantics, capability claim or live-use permission. Synthetic
scenarios only. Maintainer acceptance is required before implementing new wire
fields or persistent cursor semantics.

## Existing requirements, not new decisions

The [service contract](service-contract.md#6-atomic-events-reads-and-delivery)
requires consistent reads, whole authorized projections, stable record identity,
at-least-once delivery, separate public/private authorization and digests,
visibility checks and snapshot resynchronization on gaps. The current reader is
snapshot-only. Its decision sequence includes rejected commands and is **not**
a contiguous commit cursor. Raw privileged engine records are never public.

## Proposed minimal scope: snapshot replacement first

Implement persistent authorized snapshot installation before incremental public
replay. Public baseline views are not replayable engine state. An invalidation
may prompt an authenticated snapshot refetch, but cannot authorize fetching a
private record. Do not create public deltas by merely deleting private fields.

A consumer installation is one transaction containing its authorized payload,
that payload's digest, and the identity of its installed checkpoint. A crash
leaves either the old installation or the whole new installation. No separately
persisted cursor may imply that a partial payload was applied.

### Scope and visibility

A trusted embedding supplies tenant, auction, authenticated principal, requested
visibility, catalog-policy identity and a policy generation. None are grants
from the client. Authorization and catalog visibility are reevaluated on every
fetch, including retries. A policy-generation change invalidates a cached
installation; a denial stops disclosure and the consumer must stop serving its
old installation. This requirement cannot erase information already received.

The generation is an opaque host-owned authorization context, not a public
hash of ACLs, identity, private state or the complete catalog. Do not reuse an
installation or cache key across principal/visibility/policy contexts. Empty
visibility produces an empty authorized view, not a privileged existence oracle.

### Snapshot installation identity (proposed)

Bind the installation to tenant/auction, visibility and opaque authorization
context, plus the server checkpoint and digest of **only** the delivered payload.
A repeated identical installation is a no-op. Same identity with conflicting
content fails closed. Do not compare public and privileged digests or publish a
privileged digest in a public response. Existing reader digests are not signed
manifests and alone prove neither authenticity nor retained-history completeness.

Authentication of any manifest reference uses the deployment's authenticated
transport and server-side lookup; this proposal selects no signing algorithm or
identity provider. A copied URL never substitutes for current authorization.

## Incremental streams explicitly deferred

Before incremental execution, separately accept a closed envelope defining:

- a host-assigned stream epoch and projection-specific successor relation;
- distinction between a filtered-out commit, a rejected decision and missing
  retained history (decision-sequence arithmetic is not a solution);
- complete projection membership and stable source `(commit_id, record_index)`
  identities without revealing hidden inventory or private record counts;
- authorization-context changes, snapshot cutover and manifest expiration;
- atomic apply-once bookkeeping, conflict detection and bounded retention;
- authenticated archive/restore continuity and fail-closed epoch mismatch.

No cursor advancement is legal when an expected authorized commit is missing,
partial, incoherent, unauthorized or from another epoch. Refetch a consistent
snapshot instead. Reference-host history scanning is not authenticated archive
certification. Notification delivery evidence remains separate from consumer
installation and must never replay the auction mutation.

## Proposed executable acceptance cases

These are review cases, **not passing test claims**:

1. Invalid identity or non-true grant yields no payload and no consumer write.
2. Revocation between retries denies refetch and invalidates serving old state.
3. Catalog visibility change replaces the complete public installation; hidden
   new inventory and private maximum bids do not leak through payload or digest.
4. Public and privileged requests have distinct authorization and payload hashes;
   public content contains no privileged fingerprints or manifest references.
5. Crash before installation commit preserves old payload/checkpoint/digest;
   crash after commit returns the complete new triple on reopen.
6. Duplicate delivery installs once; same identity/different payload is refused.
7. A decision-sequence gap from a rejection is not treated as a missing event.
8. Unknown authorization generation, scope or epoch refuses stale cursor reuse.
9. Snapshot replacement does not fabricate engine bid history or notification
   delivery and never mutates the authoritative auction.
10. Recovery tests use synthetic local state and no external messages.

## Maintainer decision requested

Accept snapshot-replacement-first as the next bounded implementation and the
host-owned authorization generation/invalidation requirements above, or revise
them first. Keep incremental envelope/cursor design deferred until its visibility
and continuity rules are explicitly accepted. No implementation is authorized
merely by adding this draft.
