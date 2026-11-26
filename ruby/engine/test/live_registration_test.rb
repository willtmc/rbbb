# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"
require "rbbb/live_scheduling"

class LiveRegistrationTest < Minitest::Test
  include SchemaAssertions

  def setup
    @intent = {"type" => "register_unit", "command_id" => "register-one", "auction_id" => "auction-one",
      "unit_id" => "unit-new", "expected_schedule_revision" => 0, "reason" => "Synthetic arrival",
      "configuration" => {"currency" => "USD", "opening_minor_units" => 100, "reserve_minor_units" => 500,
        "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 25}],
        "opens_at" => "2031-04-05T11:00:00Z", "closes_at" => "2031-04-05T13:30:00Z",
        "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}}
    @snapshot = {"schedule_revision" => 0, "units" => {}, "closing_sets" => []}
    @coordinator = coordinator(@snapshot, {})
  end

  def coordinator(state, configurations, profile: RBBB::LiveScheduling::PROFILE)
    RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-one", configurations: configurations,
      snapshot: state, policy: {"minimum_shortening_lead_seconds" => 60}, profile: profile)
  end

  def register(intent = @intent, permissions: ["register"], at: "2031-04-05T12:00:00Z", target: @coordinator)
    target.register_unit(intent: intent, principal_id: "operator-one", permissions: permissions,
      effective_at: at, commit_id: "commit-one")
  end

  def test_creation_is_version_zero_null_clock_and_closed_two_record_batch
    result = register
    assert_nil result.rejection_reason
    assert_equal 1, result.state["schedule_revision"]
    assert_equal RBBB::State.empty(RBBB::Configuration.from_h(@intent["configuration"])).to_h, result.state["units"]["unit-new"]
    assert_equal %w[bidding_unit_registered closing_configuration_changed], result.records.map { |record| record["type"] }
    schema = load_schema("rfcs/proposals/flexible-live-scheduling/registration.schema.json")
    assert_matches_schema({"$ref" => "#/$defs/creation"}, result.records.first, root: schema)
    public_record = result.records.last
    refute_match(/reserve|operator|Synthetic|configuration\"|positions/, JSON.generate(public_record))
    assert_equal [{"unit_id" => "unit-new", "version" => 0}], public_record["unit_versions"]
    assert_equal @snapshot, @coordinator.snapshot
    assert_empty @coordinator.configurations
    assert_equal @intent["configuration"], result.configurations["unit-new"]
    next_coordinator = coordinator(result.state, result.configurations)
    conflict = register(@intent.merge("command_id" => "register-two", "expected_schedule_revision" => 1), target: next_coordinator)
    assert_equal "unit_id_conflict", conflict.rejection_reason
    assert_equal next_coordinator.snapshot, conflict.state
  end

  def test_future_opening_and_existing_unit_preservation
    first = register
    target = coordinator(first.state, first.configurations)
    before = Marshal.load(Marshal.dump(target.snapshot))
    intent = Marshal.load(Marshal.dump(@intent))
    intent.merge!("command_id" => "register-two", "unit_id" => "unit-second", "expected_schedule_revision" => 1)
    intent["configuration"]["opens_at"] = "2031-04-05T13:00:00Z"
    result = register(intent, target: target)
    assert_nil result.rejection_reason
    assert_equal 2, result.state["schedule_revision"]
    assert_equal before["units"]["unit-new"], result.state["units"]["unit-new"]
    assert_nil result.state["units"]["unit-second"]["last_effective_at"]
    assert_equal before, target.snapshot
    assert_equal ["unit-new"], target.configurations.keys
  end

  def test_ordered_rejections_do_not_mutate_domain
    [[@intent, [], "not_authorized"], [@intent.merge("expected_schedule_revision" => 1), ["register"], "stale_revision"]].each do |intent, permissions, reason|
      result = register(intent, permissions: permissions)
      assert_equal reason, result.rejection_reason
      assert_equal @snapshot, result.state
      assert_empty result.records
      assert_nil result.configurations
    end
    assert_equal "invalid_schedule", register(at: @intent["configuration"]["closes_at"]).rejection_reason
    exhausted = coordinator(@snapshot.merge("schedule_revision" => RBBB::MAX_SAFE_INTEGER), {})
    assert_equal "version_exhausted", register(@intent.merge("expected_schedule_revision" => RBBB::MAX_SAFE_INTEGER), target: exhausted).rejection_reason
    bounded = coordinator(@snapshot, {}, profile: RBBB::LiveScheduling::PROFILE.merge("batch_bytes" => 1))
    assert_equal "resource_limit_exceeded", register(target: bounded).rejection_reason
    assert_empty bounded.configurations
  end

  def test_registration_exact_resource_boundaries_and_plus_one
    raw = JSON.generate(@intent)
    profile = RBBB::LiveScheduling::PROFILE.merge("request_bytes" => raw.bytesize, "depth" => 4)
    assert_equal @intent, RBBB::LiveScheduling::Intent.parse_registration(raw, profile: profile)
    assert_raises(RBBB::LiveScheduling::Intent::Invalid) { RBBB::LiveScheduling::Intent.parse_registration(raw + " ", profile: profile) }
    assert_raises(RBBB::LiveScheduling::Intent::Invalid) { RBBB::LiveScheduling::Intent.parse_registration(raw, profile: profile.merge("depth" => 3)) }
    original = register
    size = RBBB::LiveScheduling.encoded_batch_size(original.records, "commit-one")
    exact = coordinator(@snapshot, {}, profile: RBBB::LiveScheduling::PROFILE.merge("batch_bytes" => size))
    assert_nil register(target: exact).rejection_reason
    assert_equal original.records, register(target: exact).records
    bounded = coordinator(@snapshot, {}, profile: RBBB::LiveScheduling::PROFILE.merge("batch_bytes" => size - 1))
    rejected = register(target: bounded)
    assert_equal "resource_limit_exceeded", rejected.rejection_reason
    assert_equal @snapshot, rejected.state
    assert_empty rejected.records
    assert_nil rejected.configurations
  end

  def test_closed_admission_semantics_and_duplicate_keys
    raw = JSON.generate(@intent)
    normalized = RBBB::LiveScheduling::Intent.parse_registration(raw)
    assert_equal "2031-04-05T13:30:00Z", normalized["configuration"]["closes_at"]
    %w[operator_id effective_at state capability].each do |field|
      assert_raises(RBBB::LiveScheduling::Intent::Invalid) { register(@intent.merge(field => true)) }
    end
    duplicate = raw.sub('"type":"register_unit"', '"type":"register_unit","type":"register_unit"')
    assert_raises(RBBB::LiveScheduling::Intent::Invalid) { RBBB::LiveScheduling::Intent.parse_registration(duplicate) }
    malformed = Marshal.load(Marshal.dump(@intent))
    malformed["configuration"]["increments"][0]["unknown"] = true
    assert_raises(RBBB::LiveScheduling::Intent::Invalid) { register(malformed) }
    malformed = Marshal.load(Marshal.dump(@intent))
    malformed["configuration"]["opens_at"] = malformed["configuration"]["closes_at"]
    assert_raises(RBBB::LiveScheduling::Intent::Invalid) { register(malformed) }
  end
end
