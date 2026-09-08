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
load. Checkpointing, durable notification delivery, group outcome commits,
live regrouping, authentication, backups and operational recovery tooling remain
separate work. It is not a deployed bidding service or a production-readiness
claim. Keep the adapter and engine source pinned when reopening existing data.
