# Durable shared-group host example

[`durable_shared_group_host.rb`](durable_shared_group_host.rb) adds a local SQLite
transaction journal to the [in-memory host](shared-group-host.md). It uses the
same accepted bidding and shared-clock rules, without new engine events or
protocol semantics. The adapter is an informative example outside the engine gem.
SQLite is a development dependency in `ruby/engine/Gemfile` only.

Construct `RBBBExamples::DurableSharedGroupHost` with `path:`, `configurations:`
(a hash of member IDs to configuration documents), and `clock:` (initial shared
clock attributes). Supply the same configuration when reopening the database.
The parent directory must exist and belong to the operator. New database files
are owner-only; existing files must be owner-owned regular files with no group
or other permissions. Treat the database and journals as private bid records.

```ruby
require_relative "examples/durable_shared_group_host"
host = RBBBExamples::DurableSharedGroupHost.new(
  path: "/private/operator-directory/group.sqlite3",
  configurations: configurations, clock: clock_attributes
)
receipt = host.submit(unit_id: "lot-12", expected_revision: 0, command: {
  command_id: "request-a", type: "place_bid", bidder_id: "bidder-a",
  maximum_minor_units: 5000, effective_at: "2030-01-01T12:59:00Z"
})
view = host.public_view # clock revision and member views from one transaction
```

Authenticate/authorize callers and assign authoritative command times before
submission. Receipt decisions are privileged; only the public clock and member
projections are suitable for bidder display. Never expose journal contents.

## Commit and recovery

Each operation opens its own connection and obtains `BEGIN IMMEDIATE` before
reading. SQLite serializes local writers across host instances and processes;
lock acquisition waits up to five seconds and then raises without accepting a
bid. `synchronous=FULL` requests SQLite's full synchronization guarantees on a
supported local filesystem. No network-filesystem or multi-server guarantee is
made.

Within the transaction, the adapter reconstructs the host from its journal,
evaluates the request, and records the normalized request and full resulting
receipt in one row. The receipt includes original engine events, rejections,
the group clock and all public member projections. Commit happens before the
caller receives the result. The journal is the durable source of truth; member
states and private clock timing are reconstructed from it rather than stored in
independently writable tables.

Exact retries return the original committed result, including after restart.
Conflicting command-ID reuse is refused. Rejected bids are retained too.
A process failure before commit is rolled back by SQLite recovery. If commit
succeeds but the caller loses the response, retrying the identical request
recovers the result without adding a second bid or extension.

Configuration documents are bound to the database. A different document is
refused. On every replay, each recomputed receipt is compared with its recorded
result, including privileged engine events. A mismatch raises instead of
silently accepting changed pricing or scheduling behavior. This is a consistency
check, not cryptographic tamper detection or a supported upgrade/migration tool.

## Verification and limits

From `ruby/engine`:

```sh
bundle install
bundle exec ruby -Ilib:test test/durable_shared_group_host_test.rb
```

Tests create private temporary databases with synthetic identities. They cover
restart recovery, actual child-process exit before/after commit, duplicate and
competing processes, rejected receipts, conflicting retries, changed configuration,
replay mismatch and proxy adjustment after restart.

This implementation replays the entire journal per operation and retains
unbounded history. It is intended for correctness evaluation, not auction-scale
load. Checkpointing, production notification transport,
live regrouping, authentication, backups and operational recovery tooling remain
separate work. It is not a deployed bidding service or a production-readiness
claim. Keep the adapter and engine source pinned when reopening existing data.

## Closing all members together

After the shared deadline, a scheduler can call:

```ruby
receipt = host.close_group(command_id: "group-close-a",
  effective_at: "2030-01-01T13:02:00Z", expected_revision: 1)
receipt.public_units # sold, no_sale or no_bid outcome for every member
```

Use the current clock revision from `public_view`. The host refuses an early or
stale close. It evaluates each member's existing `close_bidding` command against
the shared deadline in stable ID order, then commits all resulting decisions in
one journal row. The engine still computes each member's own winner and price;
this adapter adds no pricing rules or new engine events. If any member refuses
closing, none of the prepared outcomes is published. Scheduler validation failures
are exceptions without a saved receipt; the scheduler can try again when due.

The group close uses the same command-ID namespace as bids. An identical retry
returns the original per-member decisions after restart; changed request reuse
is refused. A new close request against already-closed members is refused. Bids
after committed closing receive the existing engine's closed rejection. Bid and
close processing use the same database write lock, so their race cannot publish
part of a group close. A close retains the shared clock revision; members' closed
states prevent further bidding.

`CloseReceipt#decisions` contains privileged engine records, including winner
identities and private maxima. Publish only `public_units`/`clock`. Original
member events are retained separately within the single durable group receipt.
Old bid-only journal rows keep their existing representation and replay path;
new group-close rows require this updated adapter when reopening the database.

Run `bundle exec ruby -Ilib:test test/durable_group_close_test.rb` from
`ruby/engine` for mixed outcomes, shared-deadline enforcement, member refusal,
restart/retry, actual process crashes, competing processes and privacy tests.
Notification delivery and external invoicing remain separate from this commit.

## Public result delivery

The committed journal also serves as a durable public-results outbox. No separate
enqueue step can be lost between saving a bid or group close and making its
result available. Each accepted journal entry yields one envelope containing
only `delivery_id`, `clock` and `units`; rejected bids yield none. A group close
is one envelope containing every member's public outcome. The feed contains
historical committed projections, not necessarily the latest query state.

```ruby
host.deliver_next_public(consumer_id: "public-feed") do |payload|
  # Your receiver must persist delivery_id with its applied update atomically.
  receiver.apply_once(payload.fetch("delivery_id"), payload)
  # Return normally only after the receiver confirms success; raise on failure.
end
```

This example supplies no network transport and sends no email or bidder notices.
The caller's receiver implements the actual delivery. The callback executes
outside the database lock. A failure leaves the entry pending; returning normally
acknowledges it in a separate SQLite transaction. `nil` means nothing is pending.
For separate workers, `next_public_delivery(consumer_id:)` returns an envelope
and `acknowledge_public_delivery(consumer_id:, delivery_id:)` advances its cursor.
Only the next pending envelope may be acknowledged. Repeated acknowledgment is
a no-op, and one consumer's cursor never advances another's.

Delivery is **at least once**. A crash after the receiver accepts an update but
before acknowledgment causes the same stable ID to be delivered again. The ID
combines a database-persisted stream UUID and journal sequence. The receiver must
deduplicate that ID atomically with its own side effects. This is not an
exactly-once guarantee for arbitrary external systems. Run one worker per consumer
for ordered callback execution; there is no lease preventing concurrent callbacks
for the same consumer. Separate consumers can independently read the whole stream.

The adapter validates journal replay before exposing results and explicitly
selects only public projections. Privileged events, winner identities, maxima
and command IDs are excluded. Do not use this public feed as an invoice input:
privileged, authorized accounting handoff is separate work.

Opening an existing database creates delivery metadata without changing its
journal. A new consumer starts at the oldest accepted commit, including commits
saved before this feature; nothing is sent automatically. Keep the database and
its delivery metadata together during backup/restore. Restoring an older backup
can redeliver records, so receiver deduplication remains necessary. Do not run
independently writable copies of the same database as distinct streams.

Run `bundle exec ruby -Ilib:test test/public_delivery_test.rb` from `ruby/engine`
for restart/ack recovery, actual process exit after receiver handoff, callback
failure, cursor ordering, independent consumers, privacy, retries and rollback.
Full-history replay, checkpointing and production transport operations remain
separate from this local evaluation example.
