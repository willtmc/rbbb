# RBBB Ruby reference engine

This directory contains the pure-Ruby reference implementation of the RBBB
specification.

> [!WARNING]
> The gem is an early RFC 0001 implementation. It is not production ready and
> must not be used in a live auction.

The engine will remain independent of Rails, databases, HTTP, jobs, and
authentication. Its public decision boundary is:

```ruby
decision = engine.decide(current_state, command)
new_state = engine.apply(current_state, decision.events)
```

The current implementation covers exact minor-unit money, configurable
increment tiers, opening bids, proxy competition, earlier-equal priority,
proxy clipping, challenger minimums, private leader maximum increases, and
confidential reserve pricing and status. It also enforces authoritative closing
times, configurable per-unit soft-close extensions, and bidder withdrawal of
unexecuted proxy authority. Authorized operator bid voiding preserves the
original bid, deterministically recomputes standing and executed amounts, and
emits host-facing notification intent. Audited operator commands may also
change closing time and reserve under the RFC's pre-bid and post-bid
constraints without unwinding already executed amounts. Explicit ordered
closing produces `sold`, `no_sale`, or `no_bid` terminal state. Persistence,
networking, service-level idempotency, and authentication are not implemented.

The pure engine records `operator_id`; it does not authenticate or authorize
that identity. A host must authorize the operator before submitting any
operator command and must deliver or retry any requested notifications.

```ruby
configuration = RBBB::Configuration.new(
  currency: "USD",
  opening_minor_units: 10_000,
  increments: [{from_minor_units: 0, amount_minor_units: 1_000}],
  opens_at: "2026-09-01T12:00:00Z",
  closes_at: "2026-09-01T13:00:00Z",
  extension: {trigger_window_seconds: 300, duration_seconds: 300}
)
engine = RBBB::Engine.new(configuration)
state = engine.initial_state

decision = engine.decide(state, {
  command_id: "command-1",
  type: "place_bid",
  bidder_id: "bidder-a",
  maximum_minor_units: 50_000,
  effective_at: "2026-09-01T12:10:00Z"
})
state = engine.apply(state, decision.events) if decision.accepted?
```

### Rejected commands

A command that cannot be applied yields `decision.rejected?` and no events.
`decision.rejection` is a frozen hash holding `command_id`, `reason` (one of
the enumerated codes in `specification/rejections/rejection.schema.json`), and
`status: "rejected"`, and at most one reason-specific field:
`executed_floor_minor_units`, present only with
`maximum_below_executed_amount`. There is no open-ended details object, and
the rejection is already the complete document the schema describes; a
service adapter must transmit it without adding or removing fields. The
normative rules live in
`specification/contract.md` under "Service envelope and core inputs" and the
rejection paragraph under "Events and visibility". A host must return
`executed_floor_minor_units` only to the bidder who issued the rejected
command and must never place it in a public projection.

```ruby
decision = engine.decide(state, {
  command_id: "command-2",
  type: "reduce_maximum",
  bidder_id: "bidder-a",
  maximum_minor_units: 5_000,
  effective_at: "2026-09-01T12:11:00Z"
})
if decision.rejected?
  decision.rejection
  # => {"command_id" => "command-2",
  #     "status" => "rejected",
  #     "reason" => "maximum_below_executed_amount",
  #     "executed_floor_minor_units" => 10_000}
end
```

## Snapshots, checkpoints, and the public view

`State#to_h` is the full privileged aggregate snapshot. With the host's
`auction_id`, `bidding_unit_id`, and `currency` added it satisfies
`specification/state/aggregate.schema.json`, and `RBBB::State.from_h`
rebuilds a validated state from it. It contains bidder identities, maxima,
the reserve amount, and audit history, so it must never be published.

Every privileged state-transition event already carries that snapshot, so a
host can checkpoint from the latest transition instead of replaying the
stream from version 0:

```ruby
transition = decision.events.find { |event| event.privileged? && event.type == "maximum_accepted" }
restored = engine.restore(transition)          # or RBBB::State.from_transition(configuration, transition)
restored.to_h == state.to_h                     # => true
```

`State#public_view` is the public query projection. With the same three host
fields added it satisfies `specification/state/bidding-unit.schema.json`. It
never carries a bidder, leader, or winner identity, a maximum, the reserve
amount, or audit history; serve it rather than hand-rolling a projection
from the aggregate.

## Initial closing schedule planning (unreleased)

`RBBB::InitialClosingSchedule.plan` implements the scoped
[RFC 0002](../../rfcs/0002-initial-closing-schedules.md) initial planner in this
checkout. It is not included in the published `0.1.0.pre.3` artifact.

```ruby
plan = RBBB::InitialClosingSchedule.plan(
  unit_ids: %w[lot-12 lot-20 lot-47 lot-60 lot-103 lot-110],
  opens_at: "2030-01-01T14:00:00Z",
  first_closes_at: "2030-01-01T15:00:00Z",
  lots_per_minute: 2,
  groups: [{"group_id" => "group-a", "unit_ids" => %w[lot-12 lot-47 lot-103]}]
)
plan.fetch("unit_closes_at").fetch("lot-12") # => "2030-01-01T15:02:00Z"
```

The three group members share 15:02; unrelated lots retain their minute slots.
A group's optional `closes_at` explicitly overrides its initial default.
See the [input/output contract](../../specification/initial-closing-schedule.md).
This computes a plan only. It cannot change a live auction or provide linked
soft-close behavior to independent RFC 0001 engines. Live group coordination
and proxy-adjustment scheduling rules require separate implementation.

## Shared closing clock (unreleased)

`RBBB::SharedClosingClock` is the scoped [RFC 0003](../../rfcs/0003-shared-closing-clock.md)
clock component for a fixed set of units:

```ruby
clock = RBBB::SharedClosingClock.new(
  group_id: "group-a", unit_ids: %w[lot-12 lot-47 lot-103],
  closes_at: "2030-01-01T15:00:00Z", quiet_period_seconds: 180
)
# decision comes from a synchronized unit engine, with independent extension disabled.
updated = clock.after_decision(unit_id: "lot-47", decision: decision, expected_revision: 0)
updated.public_view
```

A new qualifying accepted bid during the quiet period extends the shared
clock to bid time plus the quiet period; every member reads the same deadline.
The current leader's own proxy adjustments and rejected bids do not extend it;
an outbid bidder raising an existing maximum does (RFC 0004). Stale revisions,
unrecognized members, unsynchronized deadlines and time regression are refused.

This is **not a complete linked bidding service**. The host still must synchronize
per-unit state and atomically commit the entire group transition with events and
receipts. `due?` only indicates that the common deadline has arrived; it does not
close outcomes. Live regrouping and group transaction/recovery work are separate.
See the [component contract](../../specification/shared-closing-clock.md).

## Install the evaluation gem

Version `0.1.0.pre.3` is an experimental evaluation package. It has no runtime
dependencies and supports Ruby 3.2 and newer. Install the exact prerelease from
RubyGems.org:

```sh
gem install rbbb --version 0.1.0.pre.3
ruby -rrbbb -e 'puts [RBBB::VERSION, RBBB::SPECIFICATION_VERSION, RBBB::RELEASE_STATUS].join(" ")'
```

To build the same version from a reviewed checkout:

```sh
cd ruby/engine
bundle exec rake package:verify
gem build rbbb.gemspec
gem install ./rbbb-0.1.0.pre.3.gem
ruby -rrbbb -e 'puts [RBBB::VERSION, RBBB::SPECIFICATION_VERSION, RBBB::RELEASE_STATUS].join(" ")'
```

For local application evaluation with Bundler:

```ruby
gem "rbbb", path: "/path/to/rbbb/ruby/engine"
```

The [matching GitHub release](https://github.com/willtmc/rbbb/releases) carries
the same `.gem` artifact and its SHA-256 checksum.

The installed package exposes its implementation version, claimed
specification version, and release status as `RBBB::VERSION`,
`RBBB::SPECIFICATION_VERSION`, and `RBBB::RELEASE_STATUS`. A package version is
not, by itself, a production-readiness or compatibility claim.

## Development

```sh
bundle install
bundle exec rake
```

The default task includes `package:verify`, which builds the gem in a temporary
directory, checks the exact file allowlist, installs it into an isolated gem
home, and runs a bid through the installed artifact. Run `bundle exec rake
package:verify` when only that check is needed.
