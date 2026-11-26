# Examples

This directory contains synthetic integration examples. Examples are informative
unless they are also represented in the conformance suite, and they live outside
the packaged `rbbb` gem.

Never use production bidder data, private maximums, payment data, or copied
vendor payloads in an example.

The `rbbb` gem itself has zero runtime dependencies. Examples backed by SQLite
require the development `sqlite3` gem installed by `bundle install` in
`ruby/engine`.

## Runnable and reference Ruby examples

| File | Dependencies | Summary |
| --- | --- | --- |
| [`fixed_bid_ladder.rb`](fixed_bid_ladder.rb) | Pure Ruby (`rbbb` only) | Standalone script demonstrating RFC 0005 fixed-ladder execution and the private `maximum_not_fully_executable` bidder notice. Run with `ruby -Iruby/engine/lib examples/fixed_bid_ladder.rb`. |
| [`shared_group_host.rb`](shared_group_host.rb) | Pure Ruby (`rbbb` only) | Process-local reference host composing engine bids with `RBBB::SharedClosingClock` (RFC 0003), request serialization, and retry receipts. Guide: [`shared-group-host.md`](shared-group-host.md). |
| [`durable_shared_group_host.rb`](durable_shared_group_host.rb) | `sqlite3` (dev) | SQLite-backed durable shared-group host retaining bids, shared clock results, retry receipts, atomic group closing, and restart-safe public result delivery acknowledgments across process restarts. Guide: [`durable-shared-group-host.md`](durable-shared-group-host.md). |
| [`live_scheduling_host.rb`](live_scheduling_host.rb) | `sqlite3` (dev) | Embedded SQLite reference host for RFC 0004 (`rbbb/live_scheduling`) covering all six mutation entrypoints under `BEGIN IMMEDIATE`, durable receipts, commits, outbox delivery, and sealing. Guide: [`docs/live-scheduling-implementation.md`](../docs/live-scheduling-implementation.md). |
| [`live_scheduling_admission.rb`](live_scheduling_admission.rb) | `sqlite3` (dev) | Trusted admission boundary wrapping `LiveSchedulingHost` with server-owned authentication, authorization, permission callbacks, and bidder-safe responses. |
| [`live_scheduling_reader.rb`](live_scheduling_reader.rb) | `sqlite3` (dev) | Authorized checkpoint reader producing visibility-scoped public or privileged snapshots with content digests in the same transaction as the checkpoint. |
| [`live_scheduling_consumer.rb`](live_scheduling_consumer.rb) | `sqlite3` (dev) | SQLite snapshot-replacement consumer that reauthorizes and refetches on every read, validates scope and digest, and installs checkpoints atomically. |

## Shared soft-close group host

The [fixed-group host example](shared-group-host.md) composes real engine bids
with the shared clock, serializes simultaneous requests, and commits retry
receipts with the result in a process-local store. Its tests cover failures and
retries; durable database integration remains separate.

## Durable local shared-group host

The [SQLite host example](durable-shared-group-host.md) retains bids, shared
clock results, and retry receipts across process restarts. It tests crash
recovery and competing local processes; it remains an evaluation adapter outside
the gem.

The durable adapter also
[closes every group member in one transaction](durable-shared-group-host.md#closing-all-members-together),
with per-lot outcomes and restart-safe retries.

The [public-results outbox](durable-shared-group-host.md#public-result-delivery)
retains delivery progress across restarts and supplies stable IDs for receiver
deduplication. It sends no external messages by itself.

## Flexible live scheduling (RFC 0004)

The four `live_scheduling_*.rb` adapters (`live_scheduling_host.rb`,
`live_scheduling_admission.rb`, `live_scheduling_reader.rb`, and
`live_scheduling_consumer.rb`) demonstrate durable coordination, trusted
admission, authorized reads, and atomic snapshot-first recovery around
`RBBB::LiveScheduling::Coordinator`. See the
[live scheduling implementation guide](../docs/live-scheduling-implementation.md)
for their boundaries and test coverage.
