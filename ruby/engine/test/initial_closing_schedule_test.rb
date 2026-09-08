# frozen_string_literal: true

require_relative "test_helper"
require "json"

class InitialClosingScheduleTest < Minitest::Test
  def setup
    @vector = JSON.parse(File.read(File.expand_path("../../../conformance/initial-scheduling/nonconsecutive-group.json", __dir__)))
    @input = @vector.fetch("input")
  end

  def plan(input = @input)
    RBBB::InitialClosingSchedule.plan(**input.transform_keys(&:to_sym))
  end

  def test_portable_nonconsecutive_group_vector
    original = JSON.generate(@input)
    assert_equal @vector.fetch("expected"), plan
    assert_equal original, JSON.generate(@input)
  end

  def test_partial_last_batch_and_no_groups
    @input["unit_ids"].pop
    @input["groups"] = []
    result = plan
    assert_equal result.fetch("initial_closes_at"), result.fetch("unit_closes_at")
    assert_equal "2030-01-01T15:02:00Z", result.fetch("unit_closes_at").fetch("lot-103")
  end

  def test_different_batch_size_and_nonnumeric_labels_do_not_imply_order
    @input["unit_ids"] = %w[z alpha item-90 item-2 beta omega final]
    @input["groups"] = []
    @input["lots_per_minute"] = 3
    times = plan.fetch("unit_closes_at").values
    assert_equal ["2030-01-01T15:00:00Z"] * 3 + ["2030-01-01T15:01:00Z"] * 3 + ["2030-01-01T15:02:00Z"], times
    @input["lots_per_minute"] = RBBB::MAX_SAFE_INTEGER
    assert_equal ["2030-01-01T15:00:00Z"] * 7, plan.fetch("unit_closes_at").values
  end

  def test_explicit_override_affects_only_members
    @input["groups"][0]["closes_at"] = "2030-01-01T14:30:00Z"
    result = plan.fetch("unit_closes_at")
    assert_equal "2030-01-01T14:30:00Z", result.fetch("lot-12")
    assert_equal "2030-01-01T15:01:00Z", result.fetch("lot-60")
  end

  def test_group_and_member_order_do_not_change_plan
    @input["groups"] << {"group_id" => "group-b", "unit_ids" => ["lot-60", "lot-20"]}
    expected = plan
    @input["groups"].reverse!
    @input["groups"].each { |group| group["unit_ids"].reverse! }
    assert_equal expected, plan
  end

  def test_explicit_offsets_normalize_to_utc
    @input["first_closes_at"] = "2030-01-01T10:00:00-05:00"
    assert_equal @vector.fetch("expected"), plan
  end

  def test_result_does_not_alias_input_identities
    result = plan
    result["groups"][0]["unit_ids"][0].replace("changed")
    refute_includes @input["groups"][0]["unit_ids"], "changed"
  end

  def test_invalid_inputs_fail_without_partial_plan_or_input_mutation
    variants = []
    [0, -1, 2.5, "2", RBBB::MAX_SAFE_INTEGER + 1].each { |n| variants << @input.merge("lots_per_minute" => n) }
    [[], ["a", "a"], [nil], [""]].each { |ids| variants << @input.merge("unit_ids" => ids) }
    [nil, [{"group_id" => "x", "unit_ids" => ["unknown"]}],
     [{"group_id" => "x", "unit_ids" => []}],
     [{"group_id" => "x", "unit_ids" => ["lot-12", "lot-12"]}],
     [{"group_id" => "x", "unit_ids" => ["lot-12"], "extra" => true}],
     [{"group_id" => "x", "unit_ids" => ["lot-12"]}, {"group_id" => "y", "unit_ids" => ["lot-12"]}],
     [{"group_id" => "x", "unit_ids" => ["lot-12"]}, {"group_id" => "x", "unit_ids" => ["lot-20"]}],
     [{"group_id" => "x", "unit_ids" => ["lot-12"], "closes_at" => @input["opens_at"]}]].each { |groups| variants << @input.merge("groups" => groups) }
    [@input["opens_at"], "2030-01-01T15:00:00", "invalid"].each { |time| variants << @input.merge("first_closes_at" => time) }
    variants << @input.merge("first_closes_at" => "9999-12-31T23:59:00Z", "lots_per_minute" => 1)
    variants.each do |input|
      original = JSON.generate(input)
      assert_raises(RBBB::InvalidConfiguration) { plan(input) }
      assert_equal original, JSON.generate(input)
    end
  end
end
