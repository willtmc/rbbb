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

## Install the evaluation gem

Version `0.1.0.pre.1` is an experimental evaluation package. It has no runtime
dependencies and supports Ruby 3.2 and newer. Until a maintainer publishes it
to a registry, build an installable artifact from a reviewed commit:

```sh
cd ruby/engine
gem build rbbb.gemspec
gem install ./rbbb-0.1.0.pre.1.gem
ruby -rrbbb -e 'puts [RBBB::VERSION, RBBB::SPECIFICATION_VERSION, RBBB::RELEASE_STATUS].join(" ")'
```

For local application evaluation with Bundler:

```ruby
gem "rbbb", path: "/path/to/rbbb/ruby/engine"
```

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
