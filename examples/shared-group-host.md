# Fixed-group host example

[`shared_group_host.rb`](shared_group_host.rb) composes the accepted RFC 0001
engine and RFC 0003 clock in a process-local host. This is an executable
integration example, outside the gem and outside the normative service protocol.
It introduces no new engine commands or event meanings.

The host supports `place_bid` and `reduce_maximum` for one fixed group. Construct
it with a `SharedClosingClock` and a hash of member IDs to `Configuration`
objects. Configurations must exactly cover the clock members, start with the
same deadline, and have independent extension disabled. Authenticate and
authorize requests and assign authoritative times before calling `submit`.

```ruby
require_relative "examples/shared_group_host"
host = RBBBExamples::SharedGroupHost.new(configurations: configurations, clock: clock)
receipt = host.submit(unit_id: "lot-12", expected_revision: 0, command: {
  command_id: "request-a", type: "place_bid", bidder_id: "bidder-a",
  maximum_minor_units: 5000, effective_at: "2030-01-01T12:59:00Z"
})
host.public_view # all group members read the same authoritative closing time
```

A mutex serializes decisions across the whole group. The host constructs a
candidate containing member state, the new clock, original engine event batches,
and the retry receipt. It publishes that candidate with one reference assignment.
A failure before publication leaves every part unchanged. Public reads use the
same mutex. No callback or external notification runs between these writes.

The shared clock owns the effective deadline. Member engine snapshots retain
their original events; the host overlays the clock deadline when constructing
an engine input or public projection. An untouched member therefore observes
an extension without inventing a bid event or incrementing its bid version.
Reconstruction requires both the member engine events and committed group clock;
replaying engine events alone is insufficient. This composition is private host
storage, not a new RBBB wire snapshot format.

Within this host instance, command IDs identify requests across all members.
An exact retry returns the original receipt before checking the now-current
revision. Reusing an ID with a different member, command or expected revision
raises an error. Accepted and rejected decisions are retained. Failed validation
or failed publication retains no receipt. Receipts are privileged: their engine
decisions can contain bidder identities and maxima. Only `public_view` and the
receipt's `public_units`/`clock` projections are suitable for public display.
A receipt describes its original decision; query `public_view` for current state.

## Verification and remaining integration

From `ruby/engine`, run:

```sh
bundle exec ruby -Ilib:test test/shared_group_host_test.rb
```

Synthetic tests exercise nonconsecutive members, bids after the original deadline,
repeated extensions, simultaneous duplicate/distinct requests, failed publication,
retries, projection reconstruction, proxy adjustments, stale requests and privacy.

This store is volatile, single-process, and retains unbounded history. It does
not survive restart, coordinate multiple servers,
regroup membership, or deliver notifications. A production adapter must replace
publication with one durable transaction and group-wide lock/CAS covering state,
clock, receipts and an event outbox. Authentication, authoritative time assignment,
durable retry retention, crash recovery and outbox delivery require separate
implementation and tests. No database or deployment guarantee is claimed here.

A [separate SQLite adapter](durable-shared-group-host.md) now demonstrates local
durable transactions and restart recovery using this host. Its documented
limits still apply; this in-memory class remains unchanged.

`close_group(command_id:, effective_at:, expected_revision:)` now composes all
member closing decisions before publishing one snapshot. See the
[durable adapter closing flow](durable-shared-group-host.md#closing-all-members-together)
for deadline, retry, privacy and atomicity behavior.
