# Conformance suite

Conformance scenarios are executable policy. They allow independent
implementations to prove that the same ordered inputs produce the same
observable outcome.

The suite targets the draft specification. Scenarios governed by an accepted
RFC define the required outcomes for that draft capability.

Configuration shared by scenarios lives in `fixtures/`. A scenario references
a fixture by its filename without `.yaml`, for example:

```yaml
configuration: {fixture: usd-standard}
```

## Scenario structure

Each YAML scenario will contain:

- a unique name and specification version;
- references to the accepted RFCs it exercises;
- explicit configuration and starting state;
- an ordered command sequence; and
- expected public events, privileged events, rejections, and final state.

Private facts must be separated from public expectations so a passing engine
cannot accidentally prove correctness by leaking maximum bids.

Scenario IDs and values must be synthetic. Do not transcribe production
payloads or reproduce a proprietary platform's fixtures.

## Compatibility claims

An implementation will report the exact specification and conformance-suite
versions it passes. Selective claims must enumerate unsupported capabilities;
“RBBB compatible” by itself will not be sufficient.
