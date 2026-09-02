# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"

# Guards the dependency-free schema checker itself: a conforming public event
# envelope passes, privileged leaks and missing envelope fields fail, and a
# file-relative `$ref` that cannot be resolved fails with a clear message.
class SchemaAssertionsTest < Minitest::Test
  include SchemaAssertions

  ENVELOPE = {
    "event_id" => "command-1-0", "type" => "standing_bid_changed", "visibility" => "public",
    "auction_id" => "auction-1", "bidding_unit_id" => "unit-1", "aggregate_version" => 1,
    "event_index" => 0, "command_id" => "command-1",
    "effective_at" => "2026-09-01T12:10:00Z", "recorded_at" => "2026-09-01T12:10:00Z",
    "data" => {"standing_minor_units" => 10_000, "next_required_minor_units" => 11_000, "leader_changed" => true}
  }.freeze

  def setup
    @schema = load_schema("specification/events/public-event.schema.json")
  end

  def test_valid_public_event_passes
    assert_matches_schema(@schema, ENVELOPE)
  end

  def test_leaked_identity_in_public_data_fails
    leaked = ENVELOPE.merge("data" => ENVELOPE["data"].merge("bidder_id" => "bidder-a"))
    assert_raises(Minitest::Assertion) { assert_matches_schema(@schema, leaked) }
  end

  def test_missing_envelope_field_fails
    assert_raises(Minitest::Assertion) { assert_matches_schema(@schema, ENVELOPE.except("event_id")) }
  end

  def test_file_ref_with_pointer_fragment_resolves
    assert_matches_schema({"$ref" => "./base.schema.json#/properties/visibility"}, "public", root: @schema)
    assert_raises(Minitest::Assertion) do
      assert_matches_schema({"$ref" => "./base.schema.json#/properties/visibility"}, "secret", root: @schema)
    end
  end

  def test_unresolvable_file_ref_fails_clearly
    error = assert_raises(Minitest::Assertion) do
      assert_matches_schema({"$ref" => "./missing.schema.json"}, {}, root: @schema)
    end
    assert_match(/unresolved \$ref/, error.message)
  end
end
