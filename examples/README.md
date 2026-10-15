# Examples

This directory will contain synthetic integration examples. Examples are
informative unless they are also represented in the conformance suite.

Never use production bidder data, private maximums, payment data, or copied
vendor payloads in an example.

## Shared soft-close group host

The [fixed-group host example](shared-group-host.md) composes real engine bids
with the shared clock, serializes simultaneous requests, and commits retry
receipts with the result in a process-local store. Its tests cover failures and
retries; durable database integration remains separate.

## Durable local shared-group host

The [SQLite host example](durable-shared-group-host.md) retains bids, shared
clock results and retry receipts across process restarts. It tests crash recovery
and competing local processes; it remains an evaluation adapter outside the gem.

The durable adapter also [closes every group member in one transaction](durable-shared-group-host.md#closing-all-members-together), with per-lot outcomes and restart-safe retries.

The [public-results outbox](durable-shared-group-host.md#public-result-delivery) retains delivery progress across restarts and supplies stable IDs for receiver deduplication. It sends no external messages by itself.
