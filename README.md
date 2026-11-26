# R Triple B

Current pricing: [fixed bid ladder, odd maxima and no cut bids](specification/fixed-bid-ladder.md) (0.2.0-draft).

**A deterministic, auditable auction bidding engine.**

> [!WARNING]
> RBBB is in its initial design phase. It is not production ready and must not
> be used to accept or resolve live bids.

R Triple B is an open-source project for specifying and implementing auction
bidding behavior. The project separates the behavior of the standard from the
language used by any one implementation:

1. a language-neutral specification;
2. a language-neutral conformance suite; and
3. a production-quality Ruby reference implementation.

The first milestone is deliberately narrow: deterministic, timed online proxy
bidding with a complete audit trail. Future auction formats will be proposed
through RFCs rather than added as customer-specific hooks.

## Why this project exists

Auction behavior is full of deceptively important edge cases. When two systems
receive the same ordered commands under the same configuration, they should
reach the same result and explain why. RBBB aims to make those rules explicit,
portable, testable, and open to domain experts—not merely buried in one
application's code.

## Project shape

```text
specification/   Language-neutral concepts, schemas, and API contracts
conformance/     Portable behavior scenarios for every compliant engine
ruby/engine/     Pure-Ruby reference implementation
ruby/server/     Future deployable reference service
rfcs/            Proposed changes to normative auction behavior
docs/            Architecture, terminology, and design decisions
```

The reference implementation exposes a pure decision boundary:

```ruby
decision = engine.decide(current_state, command)
new_state = engine.apply(current_state, decision.events)
```

Rails, PostgreSQL, HTTP, and real-time delivery may surround that core, but
framework and persistence concerns do not belong inside the auction rules.

## Current status

RFC 0001 defines timed online proxy bidding; RFC 0005 replaces its pricing and
tie rules with the fixed ladder. Both are backed by
the language-neutral conformance suite. The Ruby reference engine runs every
timed-proxy scenario in that suite. This completes the behavior exercised by
the initial RFC suite, not the persistence, API, security, or operational work
required for production. The matching command, event, rejection,
configuration, and state schemas are experimental rather than a stable
compatibility promise. Anything marked `draft` may still change before the
first stable release.

The optional RFC 0004 linked soft-close reference implementation is also complete
in source, including durable host and authorized snapshot-recovery examples.
See its [integration and acceptance guide](docs/live-scheduling-implementation.md).
It is unreleased and does not certify a live service; the published evaluation
gem below predates this coordinator.

See [ROADMAP.md](ROADMAP.md), [docs/architecture.md](docs/architecture.md), and
[specification/README.md](specification/README.md) for the planned path.

## Evaluate the Ruby gem

The reference engine is packaged as the pre-stable `rbbb` gem. Install the
published legacy evaluation build from RubyGems.org with an exact prerelease version.
This version predates the fixed ladder:

```sh
gem install rbbb --version 0.1.0.pre.3
```

To build the fixed-ladder version from a reviewed current checkout (not yet published):

```sh
cd ruby/engine
bundle exec rake package:verify
gem build rbbb.gemspec
gem install ./rbbb-0.2.0.pre.1.gem
```

This artifact is for evaluation and historical replay only. It is not a hosted
service and must not be used to accept or resolve live bids. See the
[Ruby engine guide](ruby/engine/README.md) for installation and usage, or the
[GitHub releases](https://github.com/willtmc/rbbb/releases) for downloadable
artifacts and checksums.

## Contributing

Auctioneers, software operators, designers, security researchers, and
developers are all invited to contribute. A real-world edge case expressed as
a provenance-safe conformance scenario can be as valuable as code.

Before contributing, read [CONTRIBUTING.md](CONTRIBUTING.md). Normative rule
changes use the [RFC process](rfcs/README.md). Security issues should be
reported privately as described in [SECURITY.md](SECURITY.md).
General support expectations are in [SUPPORT.md](SUPPORT.md).

## License

RBBB is available under the [MIT License](LICENSE). The specification,
conformance materials, reference implementation, examples, and associated
documentation in this repository use the same license unless a file says
otherwise.

## Fixed ladder evaluation (0.2)

Odd maxima are retained, but only published ladder amounts can execute. There
are no cut bids. Run `ruby -I ruby/engine/lib examples/fixed_bid_ladder.rb` to see
the bidder notice. [RFC 0005](rfcs/0005-fixed-bid-ladder.md) defines the accepted
change and [the contract](specification/fixed-bid-ladder.md) defines its boundaries.
This is an incompatible experimental version, not a production-readiness claim.
The preserved 0.1 baseline is commit
`636ca5f104a64bb947c6cc77539d0066a5b559db`; its source tree equals the earlier
validation pin `cc1bc909c2390ea95811f4042ea7f54541e15edd`. Keep old auctions and
replays pinned to that engine; do not restore their snapshots into 0.2.
