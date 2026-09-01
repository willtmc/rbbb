# RBBB Ruby reference engine

This directory will contain the pure-Ruby reference implementation of the RBBB
specification.

> [!WARNING]
> The gem is a non-functional scaffold. It cannot evaluate bids and must not be
> used in a live auction.

The engine will remain independent of Rails, databases, HTTP, jobs, and
authentication. Its eventual public decision boundary is:

```ruby
events = engine.decide(current_state, command)
new_state = engine.apply(current_state, events)
```

Behavior will be implemented only after the corresponding RFC and conformance
scenarios are accepted.

## Development

```sh
bundle install
bundle exec rake
```
