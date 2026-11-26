# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"

# Guards the dependency-free schema checker itself: a conforming public event
# envelope passes, privileged leaks and missing envelope fields fail,
# unevaluatedProperties/if-then-else/not/anyOf enforce 2020-12 semantics, and a
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

  def test_unevaluated_properties_catches_extra_top_level_key_on_events_and_commands
    error = assert_raises(Minitest::Assertion) do
      assert_matches_schema(@schema, ENVELOPE.merge("unexpected_top_level" => true))
    end
    assert_match(/unevaluated key unexpected_top_level/, error.message)

    place_bid_schema = load_schema("specification/commands/place-bid.schema.json")
    valid_command = {
      "command_id" => "command-1", "type" => "place_bid",
      "auction_id" => "auction-1", "bidding_unit_id" => "unit-1",
      "expected_version" => 0, "effective_at" => "2026-09-01T12:10:00Z",
      "bid_id" => "bid-1", "bidder_id" => "bidder-a", "maximum_minor_units" => 10_000
    }
    assert_matches_schema(place_bid_schema, valid_command)
    assert_raises(Minitest::Assertion) do
      assert_matches_schema(place_bid_schema, valid_command.merge("operator_id" => "op-1"))
    end

    privileged_schema = load_schema("specification/events/privileged-event.schema.json")
    valid_privileged = {
      "event_id" => "command-1-0", "type" => "executed_amount_changed", "visibility" => "privileged",
      "auction_id" => "auction-1", "bidding_unit_id" => "unit-1", "aggregate_version" => 2,
      "event_index" => 1, "command_id" => "command-2",
      "effective_at" => "2026-09-01T12:12:00Z", "recorded_at" => "2026-09-01T12:12:00Z",
      "data" => {"bidder_id" => "bidder-a", "old_minor_units" => 30_000, "new_minor_units" => 10_000}
    }
    assert_matches_schema(privileged_schema, valid_privileged)
    assert_raises(Minitest::Assertion) do
      assert_matches_schema(privileged_schema, valid_privileged.merge("stray" => 1))
    end
  end

  def test_unevaluated_properties_tracks_all_of_one_of_any_of_if_then_else_and_ref
    schema = {
      "allOf" => [
        {"$ref" => "#/$defs/base"},
        {
          "if" => {"required" => ["kind"], "properties" => {"kind" => {"const" => "a"}}},
          "then" => {"properties" => {"a_only" => {"type" => "integer"}}},
          "else" => {"properties" => {"b_only" => {"type" => "string"}}}
        }
      ],
      "anyOf" => [
        {"properties" => {"tag" => {"const" => "x"}}},
        {"properties" => {"extra_tag" => {"type" => "boolean"}}}
      ],
      "unevaluatedProperties" => false,
      "$defs" => {
        "base" => {"type" => "object", "required" => ["kind"], "properties" => {"kind" => {"type" => "string"}}}
      }
    }

    assert_matches_schema(schema, {"kind" => "a", "a_only" => 1, "tag" => "x"})
    assert_matches_schema(schema, {"kind" => "b", "b_only" => "ok", "extra_tag" => true})
    assert_raises(Minitest::Assertion) do
      assert_matches_schema(schema, {"kind" => "a", "b_only" => "wrong-branch", "tag" => "x"})
    end
    assert_raises(Minitest::Assertion) do
      assert_matches_schema(schema, {"kind" => "a", "a_only" => 1, "tag" => "x", "stray" => 99})
    end
  end

  def test_if_then_else_and_not_enforce_rejection_schema
    rejection_schema = load_schema("specification/rejections/rejection.schema.json")

    assert_matches_schema(
      rejection_schema,
      {"command_id" => "cmd-1", "status" => "rejected", "reason" => "bidding_closed"}
    )
    assert_matches_schema(
      rejection_schema,
      {
        "command_id" => "cmd-2",
        "status" => "rejected",
        "reason" => "maximum_below_executed_amount",
        "executed_floor_minor_units" => 10_000
      }
    )

    assert_raises(Minitest::Assertion) do
      assert_matches_schema(
        rejection_schema,
        {"command_id" => "cmd-3", "status" => "rejected", "reason" => "maximum_below_executed_amount"}
      )
    end
    assert_raises(Minitest::Assertion) do
      assert_matches_schema(
        rejection_schema,
        {
          "command_id" => "cmd-4",
          "status" => "rejected",
          "reason" => "bidding_closed",
          "executed_floor_minor_units" => 10_000
        }
      )
    end
  end

  def test_not_rejects_matching_documents_and_does_not_mark_properties_evaluated
    schema = {
      "type" => "object",
      "properties" => {"allowed" => {"type" => "string"}},
      "not" => {"required" => ["forbidden"], "properties" => {"forbidden" => {"type" => "string"}}},
      "unevaluatedProperties" => false
    }
    assert_matches_schema(schema, {"allowed" => "yes"})
    assert_raises(Minitest::Assertion) { assert_matches_schema(schema, {"allowed" => "yes", "forbidden" => "no"}) }
    assert_raises(Minitest::Assertion) { assert_matches_schema(schema, {"allowed" => "yes", "forbidden" => 123}) }
  end

  def test_file_ref_with_pointer_fragment_resolves
    assert_matches_schema({"$ref" => "./base.schema.json#/properties/visibility"}, "public", root: @schema)
    assert_raises(Minitest::Assertion) do
      assert_matches_schema({"$ref" => "./base.schema.json#/properties/visibility"}, "secret", root: @schema)
    end
  end

  def test_bounds_and_array_uniqueness_are_not_ignored
    schema = {"type" => "array", "minItems" => 1, "maxItems" => 2, "uniqueItems" => true,
      "items" => {"type" => "integer", "minimum" => 0, "maximum" => 3}}
    assert_matches_schema(schema, [0, 3])
    [[], [1, 1], [0, 1, 2], [-1], [4]].each do |invalid|
      assert_raises(Minitest::Assertion) { assert_matches_schema(schema, invalid) }
    end
    assert_raises(Minitest::Assertion) { assert_matches_schema({"type" => "string", "maxLength" => 2}, "abc") }
  end

  def test_chained_refs_resolve_and_cycles_fail_closed
    schema = {"$ref" => "#/$defs/first", "$defs" => {
      "first" => {"$ref" => "#/$defs/second"},
      "second" => {"type" => "integer", "maximum" => 3}
    }}
    assert_matches_schema(schema, 3)
    assert_raises(Minitest::Assertion) { assert_matches_schema(schema, 4) }
    schema["$defs"]["second"] = {"$ref" => "#/$defs/first"}
    error = assert_raises(Minitest::Assertion) { assert_matches_schema(schema, 3) }
    assert_match(/cyclic schema reference/, error.message)
  end

  def test_unresolvable_file_ref_fails_clearly
    error = assert_raises(Minitest::Assertion) do
      assert_matches_schema({"$ref" => "./missing.schema.json"}, {}, root: @schema)
    end
    assert_match(/unresolved \$ref/, error.message)
  end
end
