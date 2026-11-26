# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/schema_assertions"
require "time"

# Checks fixture integrity and the already-accepted independent-unit portions.
# NO scheduling coordinator is invoked. Passing is not behavioral certification.
class FlexibleSchedulingVectorsTest < Minitest::Test
  include SchemaAssertions

  DIRECTORY = "rfcs/proposals/flexible-live-scheduling"

  def setup
    @contract = load_schema("#{DIRECTORY}/contract.schema.json")
    @submission = load_schema("#{DIRECTORY}/submission.schema.json")
    @profile = JSON.parse(ROOT.join("#{DIRECTORY}/resource-profile.json").read)
    @vectors = ROOT.join("#{DIRECTORY}/behavior-vectors.jsonl").each_line.map { |line| JSON.parse(line) }
  end

  def document(kind, value)
    assert_matches_schema({"$ref" => "#/$defs/#{kind}"}, value, root: @contract)
  end

  def test_all_review_cases_have_identifiable_unverified_vectors
    assert_equal [*1..18, 21, 22].map { |i| format("FLS-%02d", i) }, @vectors.map { |v| v.fetch("review_case") }.uniq.sort
    assert_equal 29, @vectors.size
    assert_equal 47, @vectors.sum { |v| v.fetch("steps").size }
    assert_equal @vectors.size, @vectors.map { |v| v.fetch("id") }.uniq.size
    @vectors.each { |v| assert_equal "proposed_behavior_not_coordinator_verified", v.fetch("status") }
  end

  def test_every_initial_unit_has_reproducible_baseline_commands_not_invented_history
    @vectors.each do |vector|
      vector.fetch("unit_setup").each do |unit_id, setup|
        engine = RBBB::Engine.new(RBBB::Configuration.new(**setup.fetch("configuration").transform_keys(&:to_sym)))
        state = engine.initial_state
        setup.fetch("commands").each do |command|
          decision = engine.decide(state, command)
          assert decision.accepted?, "#{vector.fetch('id')} seed rejected"
          state = engine.apply(state, decision.events)
        end
        assert_equal setup.fetch("expected_state"), state.to_h
        assert_equal state.to_h, vector.fetch("initial_state").fetch("units").fetch(unit_id)
      end
    end
  end

  def test_merge_seed_exercises_reserves_competing_maxima_and_executed_floors
    units = @vectors.find { |v| v.fetch("id") == "FLS-03" }.fetch("initial_state").fetch("units")
    assert_equal 2500, units.fetch("unit-a").fetch("reserve_minor_units")
    assert_equal "reserve_met", units.fetch("unit-a").fetch("reserve_status")
    assert_equal 4000, units.fetch("unit-b").fetch("reserve_minor_units")
    assert_equal "reserve_not_met", units.fetch("unit-b").fetch("reserve_status")
    assert_equal 2, units.fetch("unit-c").fetch("positions").size
    assert_operator units.fetch("unit-c").fetch("positions").fetch("bidder-c").fetch("executed_minor_units"), :>, 1000
  end

  def test_every_snapshot_has_consistent_membership_and_valid_unit_state
    @vectors.each do |vector|
      states = [vector.fetch("initial_state"), *vector.fetch("steps").map { |s| s.fetch("expected").fetch("state") }]
      states.each do |state|
        members = state.fetch("closing_sets").flat_map do |closing_set|
          document("closing_set", closing_set)
          closing_set.fetch("member_unit_ids").each do |unit_id|
            unit = state.fetch("units").fetch(unit_id)
            assert_equal closing_set.fetch("closes_at"), unit.fetch("closes_at")
            assert_equal unit, RBBB::State.from_h(unit).to_h
          end
        end
        assert_equal state.fetch("units").keys.sort, members.sort
        assert_equal members.size, members.uniq.size
      end
    end
  end

  def test_manual_vectors_have_exact_closed_record_shapes_and_preserve_bid_state
    each_step do |vector, before, action, expected|
      next unless action.fetch("kind") == "operator_edit"

      if expected.fetch("rejection_reason") == "invalid_request"
        assert_raises(Minitest::Assertion) { document("command", action.fetch("command")) }
        next
      end
      document("command", action.fetch("command"))
      assert_matches_schema(@submission, action.fetch("submitted_intent"))
      next if expected.fetch("new_records").empty?

      records = expected.fetch("new_records")
      assert_equal %w[closing_configuration_committed closing_configuration_changed closing_change_notice], records.map { |r| r.fetch("type") }
      %w[audit_event public_change notification_intent].zip(records).each { |kind, record| document(kind, record) }
      assert_equal [action.fetch("trusted_commit_id")], records.map { |r| r.fetch("commit_id") }.uniq
      assert_equal action.fetch("command").fetch("resulting_closing_sets"), records[1].fetch("resulting_closing_sets")
      before.fetch("units").each do |unit_id, unit|
        unchanged = unit.except("version", "last_effective_at", "closes_at")
        assert_equal unchanged, expected.fetch("state").fetch("units").fetch(unit_id).except("version", "last_effective_at", "closes_at"), vector.fetch("id")
      end
    end
  end

  def test_scheduling_records_agree_with_exact_expected_snapshots
    each_step do |_vector, before, _action, expected|
      expected.fetch("new_records").select { |r| r["type"] == "closing_configuration_changed" }.each do |record|
        after = expected.fetch("state")
        assert_equal before.fetch("schedule_revision") + 1, record.fetch("schedule_revision")
        assert_equal after.fetch("schedule_revision"), record.fetch("schedule_revision")
        record.fetch("unit_versions").each do |entry|
          unit = after.fetch("units").fetch(entry.fetch("unit_id"))
          assert_equal unit.fetch("version"), entry.fetch("version")
          assert_equal before.fetch("units").fetch(entry.fetch("unit_id")).fetch("version") + 1, unit.fetch("version")
          assert_equal record.fetch("effective_at"), unit.fetch("last_effective_at")
        end
        record.fetch("resulting_closing_sets").each do |closing_set|
          assert_includes after.fetch("closing_sets"), closing_set
        end
      end
    end
  end

  def test_bid_and_close_subrecords_match_accepted_independent_unit_behavior
    each_step do |vector, before, action, expected|
      next unless %w[bid close_group].include?(action.fetch("kind"))

      closing_set = before.fetch("closing_sets").find do |set|
        action["unit_id"] ? set.fetch("member_unit_ids").include?(action["unit_id"]) : set["group_id"] == action.fetch("group_id")
      end
      unit_ids = action["unit_id"] ? [action["unit_id"]] : closing_set.fetch("member_unit_ids")
      unit_ids.each do |unit_id|
        config = vector.fetch("unit_setup").fetch(unit_id).fetch("configuration").merge(
          "closes_at" => closing_set.fetch("closes_at"), "extension" => closing_set.fetch("extension"))
        engine = RBBB::Engine.new(RBBB::Configuration.new(**config.transform_keys(&:to_sym)))
        state = RBBB::State.from_h(before.fetch("units").fetch(unit_id))
        decision = engine.decide(state, action.fetch("command"))
        actual = expected.fetch("new_records").select { |r| r["unit_id"] == unit_id }.map { |r| r.fetch("event") }
        assert_equal decision.events.map(&:to_h), actual
        assert_equal engine.apply(state, decision.events).to_h, expected.fetch("state").fetch("units").fetch(unit_id)
        assert_equal decision.rejection.fetch("reason"), expected.fetch("rejection_reason") if decision.rejected?
      end
      expected.fetch("new_records").reject { |r| r.key?("unit_id") }.each { |r| document("public_change", r) }
    end
  end

  def test_rejections_rollbacks_and_retries_expect_no_new_domain_mutation
    @vectors.each do |vector|
      before = vector.fetch("initial_state")
      vector.fetch("steps").each_with_index do |step, index|
        action, expected = step.values_at("action", "expected")
        if expected.fetch("new_records").empty?
          assert_equal before, expected.fetch("state")
        end
        assert_matches_schema(@submission, action.fetch("submitted_intent")) if action.fetch("kind") == "retry"
        if action.fetch("kind") == "retry" && expected.key?("replayed_step")
          original = expected.fetch("replayed_step")
          assert_operator original, :<, index
          prior = vector.fetch("steps")[original].fetch("expected")
          assert prior.fetch("receipt_retained")
          prior["rejection_reason"].nil? ? assert_nil(expected["rejection_reason"]) : assert_equal(prior["rejection_reason"], expected["rejection_reason"])
        end
        before = expected.fetch("state")
      end
    end
  end

  def test_accepted_shortening_respects_the_trusted_minimum_lead
    @vectors.each { |vector| document("scheduling_policy", vector.fetch("scheduling_policy")) }
    each_step do |vector, before, action, expected|
      next unless action.fetch("kind") == "operator_edit" && expected.fetch("new_records").any?

      lead = vector.fetch("scheduling_policy").fetch("minimum_shortening_lead_seconds")
      earliest = Time.iso8601(action.fetch("command").fetch("effective_at")) + lead
      action.fetch("command").fetch("resulting_closing_sets").each do |closing_set|
        closes_at = Time.iso8601(closing_set.fetch("closes_at"))
        closing_set.fetch("member_unit_ids").each do |unit_id|
          next unless closes_at < Time.iso8601(before.fetch("units").fetch(unit_id).fetch("closes_at"))

          assert_operator closes_at, :>=, earliest, "#{vector.fetch('id')} shortens #{unit_id} inside the minimum lead"
        end
      end
    end
  end

  def test_minimum_lead_boundary_accepts_exactly_the_lead_and_rejects_one_millisecond_less
    outcomes = @vectors.select { |v| v.fetch("review_case") == "FLS-22" }.to_h do |vector|
      [vector.fetch("id"), vector.fetch("steps").first.fetch("expected").fetch("rejection_reason")]
    end
    assert_equal({"FLS-22-minimum" => nil, "FLS-22-short" => "shortening_lead_too_short"}, outcomes)
    assert_equal "shortening_lead_too_short", @vectors.find { |v| v.fetch("id") == "FLS-07-future" }.fetch("steps").first.fetch("expected").fetch("rejection_reason")
    assert_raises(Minitest::Assertion) { document("scheduling_policy", {"minimum_shortening_lead_seconds" => 0}) }
    refute_includes @submission.fetch("properties").keys, "minimum_shortening_lead_seconds"
  end

  def test_non_leader_raise_that_takes_the_lead_extends_the_whole_group
    step = @vectors.find { |v| v.fetch("id") == "FLS-21" }.fetch("steps").first
    assert_equal "bid", step.fetch("action").fetch("kind")
    events = step.fetch("expected").fetch("new_records").select { |r| r.key?("unit_id") }.map { |r| r.fetch("event") }
    assert_equal %w[maximum_increased standing_bid_changed closing_time_changed], events.map { |e| e.fetch("type") }
    assert events.find { |e| e.fetch("type") == "standing_bid_changed" }.fetch("leader_changed")
    group = step.fetch("expected").fetch("state").fetch("closing_sets").find { |set| set["group_id"] == "group-left" }
    assert_equal %w[unit-a unit-b], group.fetch("member_unit_ids")
    assert_equal "2031-04-17T15:02:00Z", group.fetch("closes_at")
  end

  def test_submission_cannot_supply_server_identity_or_clock
    sample = JSON.parse(ROOT.join("#{DIRECTORY}/merge-example.json").read).fetch("command")
    intent = sample.except("operator_id", "effective_at")
    assert_matches_schema(@submission, intent)
    %w[operator_id effective_at authorized].each do |key|
      assert_raises(Minitest::Assertion) { assert_matches_schema(@submission, intent.merge(key => "untrusted")) }
    end
    assert_equal @contract.fetch("$defs").fetch("command").fetch("required") - %w[operator_id effective_at], @submission.fetch("required")
  end

  def test_profile_and_schema_enforce_4096_member_boundary_not_a_capacity_claim
    assert_equal "proposed_not_load_certified", @profile.fetch("status")
    assert_equal 4096, @profile.fetch("max_affected_units")
    {"max_affected_units" => "expected_units", "max_resulting_closing_sets" => "resulting_closing_sets",
      "max_retired_group_ids" => "retired_group_ids"}.each do |limit, field|
      assert_equal @profile.fetch(limit), @contract.fetch("$defs").fetch("command").fetch("properties").fetch(field).fetch("maxItems")
      assert_equal @profile.fetch(limit), @submission.fetch("properties").fetch(field).fetch("maxItems")
    end
    sample = JSON.parse(ROOT.join("#{DIRECTORY}/merge-example.json").read).fetch("command")
    ids = 4096.times.map { |i| "unit-#{i}" }
    sample["expected_units"] = ids.map { |id| {"unit_id" => id, "version" => 1} }
    sample["resulting_closing_sets"][0]["member_unit_ids"] = ids
    document("command", sample)
    assert_operator JSON.generate(sample).bytesize, :<=, @profile.fetch("max_submission_utf8_bytes")
    sample["expected_units"] << {"unit_id" => "unit-overflow", "version" => 1}
    assert_raises(Minitest::Assertion) { document("command", sample) }
    sample["expected_units"].pop
    ids << "unit-overflow"
    assert_raises(Minitest::Assertion) { document("command", sample) }
  end

  private

  def each_step
    @vectors.each do |vector|
      before = vector.fetch("initial_state")
      vector.fetch("steps").each do |step|
        yield vector, before, step.fetch("action"), step.fetch("expected")
        before = step.fetch("expected").fetch("state")
      end
    end
  end
end
