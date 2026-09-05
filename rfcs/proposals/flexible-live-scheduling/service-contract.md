# Proposed reference-service transaction contract

Status: **proposed; no service implementation or load certification**.
This resolves the initial design choices in the [RFC](../../flexible-live-scheduling.md),
not the acceptance or implementation gate. Other implementations may use a
semantically equivalent sequencer/fenced transaction.

## 1. Ordering and transaction boundary

The reference design uses a database transaction and an **auction-row lock**.
Every state-changing entry point participates: bids, private maximum changes,
unit registration, group edits, schedule edits, extensions, voids, and closing.
There is no independent per-unit write path around this lock. A process-local
mutex is insufficient. Different auctions may progress concurrently.

Under the lock, the service:

1. Resolves a retained command receipt before allocating fresh authoritative time.
2. Captures authoritative time at millisecond precision, clamped to at least the
   auction's last durable decision time. A clock rollback raises operational
   telemetry but cannot backdate a command. Equal timestamps use durable order.
3. Reads the complete affected topology and unit states in the same transaction.
4. Validates versions, authorization context, eligibility and the requested result.
5. Computes the entire decision and its bounded event batch before mutation.
6. Commits state changes, immutable domain events, notification intent/outbox,
   the command receipt, and a private decision sequence in **one transaction**.

The commit is the linearization point. Each affected unit advances once for the
logical accepted command, even if it has several event records. A bid that also
extends its group advances the bidding unit once, not twice; other extended
members advance once. Scheduling revision advances once when the command changes
membership, deadlines, policies, registered scheduling membership, or terminal
eligibility. Private-only bid changes do not advance scheduling revision, but do
advance their unit version. A no-op edit returns `no_change`, not a new revision.
Revision overflow rejects with `version_exhausted`; never wrap or saturate.

Deadlocks or serialization failures may retry the entire transaction only after
rollback is established. An ambiguous connection failure after COMMIT requires
receipt lookup, not a fresh unconditional write. A rolled-back attempt has no
published identity, event, notification, or promised result.

## 2. Submission, authoritative commands, and identity

The existing proposal `command` document is the **trusted coordinator input**,
not a directly accepted public HTTP body. A submitted operator intent contains
its command ID, auction, requested change, reason, expected versions, and
shortening intent. It must not supply `operator_id` or `effective_at`; the
service supplies them from authenticated identity and the ordered clock.
Transport authentication happens before receipt disclosure. Permissions are
checked for the operation and, separately, for shortening. No JSON boolean
asserting authorization is trusted.

The receipt key is `(tenant_id, auction_id, command_id)`; tenant identity comes
from the trusted deployment context. A key is permanently bound to its original
principal and normalized submitted intent. A different principal cannot claim
another actor's receipt or learn its private contents.

For fingerprinting, reject unknown properties, duplicate JSON object keys, and
duplicate set members first. Reject invalid UTF-8 and unpaired Unicode surrogates
rather than repairing them during canonicalization. Normalize
set-valued arrays (member IDs, retired IDs, unit-version vectors and resulting
closing sets) into identifier order. Sort closing sets by the tuple
`["group", group_id]` or `["unit", sole_member_id]`. Normalize closing timestamps
to UTC with three fractional digits. Preserve the reason exactly, without
trimming or Unicode normalization. Hash the RFC 8785 canonical UTF-8 JSON object
`{"principal_id": trusted_principal_id, "intent": normalized_intent}` with SHA-256. Do not include server-assigned time or
a retry's transport metadata. Do not expose this privileged fingerprint publicly.

Identical intent with the same key and currently authorized principal returns
the original complete receipt, including its original time and commit identity.
It creates no additional events or outbox entries. Different normalized intent
under that key returns `command_id_reused`. A correction uses a new command ID.
A retry does not silently revalidate an old rejected decision against new state.

## 3. Retention and rejected decisions

No receipt TTL is permitted while an auction accepts mutations. Archival first
atomically seals the auction against new writes. Receipts and their index are
then preserved with its audit archive; restoration cannot resume mutation
without restoring deduplication history. A sealed auction rejects new IDs with
`auction_sealed`. Authorized retrieval of a retained receipt is not reopening.

A well-formed, authenticated request that reaches an ordered domain decision
retains its rejection receipt too. Rejection does not change bidding/scheduling
state, domain history, public events, or notification intent. The private receipt
and decision sequence are control-plane bookkeeping, not a domain transition.
Authentication, malformed-body and pre-admission size failures are transport
failures, not durable domain decisions. A reused ID never overwrites its receipt.

## 4. Stable validation precedence

Transport authentication, raw size and schema validation precede sequencing.
Inside the ordered decision, use this precedence for simultaneously invalid
requests, stopping at the first failure:

1. retained ID conflict (or return an authorized identical receipt);
2. sealed auction / unsupported capability;
3. operation authorization;
4. advertised affected-set limits;
5. scheduling revision, then unit-version preconditions;
6. duplicated membership / conflicting group definitions / incomplete affected set;
7. elapsed or terminal units;
8. out-of-order trusted time (defense for embedded callers);
9. invalid extension policy or invalid requested deadline;
10. shortening permission and explicit shortening intent;
11. no scheduling effect;
12. revision exhaustion and encoded batch limits.

Exact conflicting IDs and before-state diagnostics remain privileged. The
existing closed rejection document avoids echoing free-text reasons or bids.
Discovery follows both old and requested groups under the lock, including all
members of any existing target group. An omitted member cannot escape validation
by being absent from the submitted version vector.

## 5. Resource profile

The proposed initial profile is `reference_scheduling_4096_v1`:

| Bound | Maximum |
| --- | ---: |
| Affected units, including discovered existing members | 4,096 |
| Resulting closing sets | 4,096 |
| Retired group IDs | 4,096 |
| JSON object/array nesting depth (root object is depth 1) | 16 |
| Submitted UTF-8 JSON body, after decompression and before parsing | 4,194,304 bytes |
| Fully encoded domain/outbox batch, including all visibility projections | 16,777,216 bytes |

These are per-operation ceilings, **not an auction-size limit or measured
capacity claims**. An auction may contain more units than one atomic edit can
affect. A deployment may advertise
a smaller immutable profile for an auction before accepting commands. Profile
changes cannot invalidate an in-flight preview: apply a different profile only
at an explicit sealed migration boundary or to new auctions. Previews return the
profile identity. A host must never split one promised atomic operation into
several smaller writes as an overflow workaround.

The request-byte limit bounds parsing work; the discovered-unit limit bounds
computation under the lock; the encoded-batch limit bounds persistence/outbox
work. Check all three. Queues with smaller message limits carry an authenticated
manifest reference rather than fragments pretending to be independent commits.
The service must prove these boundaries before advertising this capability.

## 6. Atomic events, reads, and delivery

A manual scheduling commit contains these logical records in fixed order:

1. `closing_configuration_committed` — privileged before/after audit;
2. `closing_configuration_changed` — complete public scheduling change;
3. `closing_change_notice` — privileged deterministic notification intent.

Their common commit ID identifies the transaction. Record identity is
`(commit_id, record_index)`; indices are 0, 1, 2. These coordinator records are
not baseline per-unit event envelopes. Unit updates and coordinator records
cannot commit separately.

For a bid or group close, the normalized batch contains `{unit_id, event}`
records, ordered by unit ID and then baseline decision-event order, followed by
one `closing_configuration_changed` record if scheduling revision advanced.
This last record is the complete scheduling delta. It creates no manual-edit
notification intent. Identity remains `(commit_id, record_index)` across the
entire batch, including per-unit records.

Replay applies baseline unit events first. For each unit in the scheduling
delta's version vector, assign its declared version, the closing time from its
resulting closing set, and the commit's effective time as `last_effective_at`.
Preserve all other unit fields. A unit already advanced by baseline events must
have the same declared version; every other affected unit must advance exactly
once. Replace affected closing sets and retire the named groups; preserve all
unaffected sets. Assign the declared scheduling revision. Audit and notice
records do not apply a second mutation. Reject an incoherent batch rather than
repairing it. Serialize closing sets in the same group/unit tuple order used
for intent normalization; member IDs and version vectors use identifier order.

A per-unit subscriber encountering this capability must consume the complete
commit with a coordinator-aware projector or refetch a consistent snapshot.
It cannot pretend these deltas are ordinary independent commands or fabricate
bid history. Baseline-only consumers must reject this unsupported capability.

Readers use one consistent snapshot or a complete commit boundary. Outbox
publication is at least once. Consumers deduplicate record identities and apply
one whole authorized projection atomically, or fetch a snapshot at its revision.
A gap causes resynchronization; a consumer must not advance its cursor past a
missing or partially applied commit. Public/private manifests have separate
content digests and authorization. Do not expose hashes of privileged payloads.
Catalog visibility remains a host check, including newly registered inventory.

Notification retry never repeats the scheduling mutation. The host freezes a
delivery plan, uses stable recipient/channel/intent deduplication keys, and
tracks delivery evidence separately. Exactly-once external message delivery is
not promised. No tests in this proposal contact customers or send messages.

## 7. Acceptance gates

Before implementation can advertise support, require:

- all behavioral vectors executed against the coordinator, not just parsed;
- two independent database sessions racing bid/edit, edit/edit, and close/edit;
- crash injection before commit, after commit/before response, and during outbox delivery;
- receipt replay after deadline expiry, rejection replay, principal mismatch,
  changed-intent retries, and seal/archive/restore;
- full 4,096-unit merge/split, boundary-plus-one rejection, raw-body and encoded
  batch boundaries, and no partial mutation at any failure point;
- proof that every mutation entry point acquires the auction ordering boundary;
- cross-implementation event/envelope mapping and deterministic replay.

RFC acceptance records agreed semantics. Implementation certification is a later
state; neither proposed fixtures nor an accepted RFC means these gates passed.
