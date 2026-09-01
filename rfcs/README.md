# Request for comments process

An RFC is required for any new or changed normative auction behavior, public
contract, compatibility guarantee, or governance model.

## Process

1. Open an issue describing the policy question before writing a large RFC.
2. Copy `0000-template.md` and use a temporary descriptive filename.
3. Include synthetic conformance scenarios that make the decision observable.
4. Open a pull request and invite domain and implementation review.
5. A maintainer records the decision and assigns the permanent RFC number.
6. Accepted behavior lands in the specification, conformance suite, and
   reference implementation together.

An RFC may be proposed, accepted, rejected, withdrawn, or superseded. Merging a
proposed document does not make it normative unless its status says accepted.

## Evaluation questions

- Can an auctioneer explain the behavior in plain language?
- Is the result deterministic for the same ordered inputs?
- Are ordering and serialization boundaries explicit?
- Does the design preserve private bidding facts?
- Can another language implement it from the public contract alone?
- Are failure, retry, and audit behavior testable?
- Is configuration finite and composable rather than arbitrary code?
