# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/live_scheduling_host"

class LiveSchedulingCoordinatorTest < Minitest::Test
  class FaultHost < RBBBExamples::LiveSchedulingHost
    attr_accessor :fault, :commit_id
    private
    def next_commit_id = commit_id || super
    def before_commit(_db)
      raise ResponseLost, "before commit" if fault == "before_commit"
    end
    def after_commit(_response)
      raise ResponseLost, "after commit" if fault == "after_commit_before_response"
    end
  end

  def normalize_times(value)
    case value
    when Hash then value.transform_values { |v| normalize_times(v) }
    when Array then value.map { |v| normalize_times(v) }
    when String
      value.match?(/\A\d{4}-\d{2}-\d{2}T/) ? RBBB::Timestamp.parse(value).utc.iso8601(3) : value
    else value
    end
  end

  vectors = File.readlines(File.expand_path("../../../rfcs/proposals/flexible-live-scheduling/behavior-vectors.jsonl", __dir__)).map { |line| JSON.parse(line) }
  vectors.each do |vector|
    define_method("test_coordinator_executes_#{vector.fetch('id').tr('-', '_')}") do
      Dir.mktmpdir do |dir|
        configs = vector.fetch("unit_setup").transform_values { |setup| setup.fetch("configuration") }
        units = vector.fetch("unit_setup").transform_values do |setup|
          engine = RBBB::Engine.new(RBBB::Configuration.from_h(setup.fetch("configuration")))
          setup.fetch("commands").reduce(engine.initial_state) { |state, command| engine.apply(state, engine.decide(state, command).events) }.to_h
        end
        snapshot = vector.fetch("initial_state").merge("units" => units)
        at = "2031-04-17T12:00:00Z"
        arguments = {path: File.join(dir, "auction.sqlite3"), tenant_id: "tenant-demo", auction_id: "auction-demo",
          configurations: configs, snapshot: snapshot, policy: vector.fetch("scheduling_policy"), clock: -> { at }}
        host = FaultHost.new(**arguments)
        vector.fetch("steps").each_with_index do |step, index|
          action, expected = step.values_at("action", "expected")
          before = host.records
          previous_snapshot = host.snapshot
          at = action["observed_clock"] || action.dig("command", "effective_at") || at
          host.commit_id = action["trusted_commit_id"]
          host.fault = action["fault"]
          response = begin
            case action["kind"]
            when "host_display_order"
              {"rejection_reason" => nil, "receipt_retained" => false}
            when "operator_edit"
              host.edit(intent: action["submitted_intent"], principal_id: action["command"]["operator_id"], permissions: action["trusted_permissions"])
            when "bid"
              command = action["command"].reject { |key, _| %w[effective_at bidder_id].include?(key) }
              host.bid(unit_id: action["unit_id"], command: command, principal_id: action["command"]["bidder_id"])
            when "close_group"
              host.close(group_id: action["group_id"], command_id: action["command"]["command_id"], principal_id: "operator-demo", permissions: ["close"])
            when "retry"
              host.edit(intent: action["submitted_intent"], principal_id: "operator-demo", permissions: ["schedule", "shorten"])
            else flunk "unhandled coordinator action"
            end
          rescue RBBB::LiveScheduling::Intent::Invalid
            {"rejection_reason" => "invalid_request", "receipt_retained" => false}
          rescue RBBBExamples::LiveSchedulingHost::ResponseLost
            # A fresh adapter/database connection must observe precisely the
            # durable commit boundary, not the crashed object's local memory.
            host = FaultHost.new(**arguments)
            {"rejection_reason" => nil, "receipt_retained" => action["fault"] != "before_commit"}
          end
          label = "#{vector['id']} step #{index}"
          assert_equal normalize_times(expected["state"]), normalize_times(host.snapshot), "#{label} state"
          assert_equal normalize_times(expected["new_records"]), normalize_times(host.records.drop(before.size)), "#{label} records"
          expected["rejection_reason"].nil? ? assert_nil(response["rejection_reason"], label) : assert_equal(expected["rejection_reason"], response["rejection_reason"], label)
          assert_equal expected["receipt_retained"], response["receipt_retained"], "#{label} receipt"
          if expected.key?("replayed_step")
            assert response["replayed"], label
            assert_equal normalize_times(vector['steps'][expected['replayed_step']]['expected']['new_records']), normalize_times(response['records']), "#{label} original receipt"
          end
          replayed = RBBB::LiveScheduling::Projector.apply(snapshot: previous_snapshot, configurations: configs,
            records: host.records.drop(before.size))
          assert_equal normalize_times(host.snapshot), normalize_times(replayed), "#{label} whole-commit replay"
        end
      end
    end
  end

  def test_leader_changing_reduce_maximum_extension_replays_cleanly_through_projector
    config = {"currency" => "USD", "opening_minor_units" => 100, "reserve_minor_units" => nil,
      "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 100}],
      "opens_at" => "2031-04-17T12:00:00Z", "closes_at" => "2031-04-17T13:00:00Z",
      "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}
    configs = {"unit-a" => config, "unit-b" => config}
    engine = RBBB::Engine.new(RBBB::Configuration.from_h(config.merge("extension" => nil)))
    # bidder-a bids 500 (priority 1), bidder-b matches 500 (priority 2), bidder-a raises to 700 (priority 3).
    # When bidder-a reduces back to 500 (priority 4), bidder-b wins the tie on earlier priority (2 < 4).
    state_a = engine.initial_state
    [
      {"command_id" => "a1", "type" => "place_bid", "bidder_id" => "bidder-a", "maximum_minor_units" => 500, "effective_at" => "2031-04-17T12:10:00Z"},
      {"command_id" => "b1", "type" => "place_bid", "bidder_id" => "bidder-b", "maximum_minor_units" => 500, "effective_at" => "2031-04-17T12:11:00Z"},
      {"command_id" => "a2", "type" => "place_bid", "bidder_id" => "bidder-a", "maximum_minor_units" => 700, "effective_at" => "2031-04-17T12:12:00Z"}
    ].each do |cmd|
      state_a = engine.apply(state_a, engine.decide(state_a, cmd).events)
    end
    assert_equal "bidder-a", state_a.leader_id
    assert_equal 500, state_a.standing_minor_units
    snapshot = {
      "schedule_revision" => 0,
      "units" => {"unit-a" => state_a.to_h, "unit-b" => engine.initial_state.to_h},
      "closing_sets" => [{"group_id" => "group-1", "member_unit_ids" => %w[unit-a unit-b],
        "closes_at" => "2031-04-17T13:00:00Z", "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}]
    }
    coordinator = RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo", configurations: configs,
      snapshot: snapshot, policy: {"minimum_shortening_lead_seconds" => 60})
    result = coordinator.bid(
      unit_id: "unit-a",
      command: {"type" => "reduce_maximum", "command_id" => "reduce-flip", "bidder_id" => "bidder-a", "maximum_minor_units" => 500},
      effective_at: "2031-04-17T12:59:30Z",
      commit_id: "commit-reduce-flip"
    )
    assert_nil result.rejection_reason
    assert_equal "bidder-b", result.state["units"]["unit-a"]["leader_id"]
    assert_equal "2031-04-17T13:01:30Z", result.state["units"]["unit-a"]["closes_at"]
    assert_equal "2031-04-17T13:01:30Z", result.state["units"]["unit-b"]["closes_at"]

    replayed = RBBB::LiveScheduling::Projector.apply(snapshot: snapshot, configurations: configs, records: result.records)
    assert_equal normalize_times(result.state), normalize_times(replayed)
  end

  def test_projector_rejects_forged_and_out_of_window_bid_extensions
    config = {"currency" => "USD", "opening_minor_units" => 100, "reserve_minor_units" => nil,
      "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 100}],
      "opens_at" => "2031-04-17T12:00:00Z", "closes_at" => "2031-04-17T13:00:00Z",
      "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}
    configs = {"unit-a" => config}
    empty = RBBB::State.empty(RBBB::Configuration.from_h(config)).to_h
    snapshot = {
      "schedule_revision" => 0,
      "units" => {"unit-a" => empty},
      "closing_sets" => [{"group_id" => nil, "member_unit_ids" => ["unit-a"],
        "closes_at" => "2031-04-17T13:00:00Z", "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}]
    }
    coordinator = RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo", configurations: configs,
      snapshot: snapshot, policy: {"minimum_shortening_lead_seconds" => 60})

    # 1. Forged extension on an out-of-window bid (at 12:30:00Z, trigger window is 60s before 13:00:00Z)
    early = coordinator.bid(
      unit_id: "unit-a",
      command: {"type" => "place_bid", "command_id" => "early-bid", "bidder_id" => "bidder-a", "maximum_minor_units" => 500},
      effective_at: "2031-04-17T12:30:00Z",
      commit_id: "commit-early"
    )
    assert_nil early.rejection_reason
    forged_records = RBBB::LiveScheduling.copy(early.records)
    forged_close = "2031-04-17T13:05:00Z"
    forged_records.each { |r| r["event"]["closes_at"] = forged_close if r["event"].key?("closes_at") }
    forged_records << {"unit_id" => "unit-a", "event" => {"type" => "closing_time_changed",
      "command_id" => "early-bid", "aggregate_version" => 1, "closes_at" => forged_close}}
    forged_records << {"capability" => RBBB::LiveScheduling::CAPABILITY, "type" => "closing_configuration_changed",
      "command_id" => "early-bid", "commit_id" => "commit-early", "auction_id" => "auction-demo",
      "effective_at" => "2031-04-17T12:30:00Z", "visibility" => "public", "schedule_revision" => 1,
      "unit_versions" => [{"unit_id" => "unit-a", "version" => 1}],
      "resulting_closing_sets" => [{"group_id" => nil, "member_unit_ids" => ["unit-a"],
        "closes_at" => forged_close, "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}],
      "retired_group_ids" => []}
    assert_raises(RBBB::InvalidState) do
      RBBB::LiveScheduling::Projector.apply(snapshot: snapshot, configurations: configs, records: forged_records)
    end

    # 2. Forged duration on an in-window bid (should extend to 13:01:30Z, forged to 13:10:00Z)
    in_window = coordinator.bid(
      unit_id: "unit-a",
      command: {"type" => "place_bid", "command_id" => "late-bid", "bidder_id" => "bidder-a", "maximum_minor_units" => 500},
      effective_at: "2031-04-17T12:59:30Z",
      commit_id: "commit-late"
    )
    assert_nil in_window.rejection_reason
    tampered = RBBB::LiveScheduling.copy(in_window.records)
    tampered.each do |record|
      if record.key?("event")
        record["event"]["closes_at"] = "2031-04-17T13:10:00Z" if record["event"].key?("closes_at")
      elsif record["type"] == "closing_configuration_changed"
        record["resulting_closing_sets"].first["closes_at"] = "2031-04-17T13:10:00Z"
      end
    end
    assert_raises(RBBB::InvalidState) do
      RBBB::LiveScheduling::Projector.apply(snapshot: snapshot, configurations: configs, records: tampered)
    end
  end

  def test_projector_assigns_accurate_privileged_and_public_event_visibility
    assert_equal :privileged, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "executed_amount_changed"})
    assert_equal :privileged, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "notification_requested"})
    assert_equal :privileged, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "bidding_closed", "positions" => {}})
    assert_equal :privileged, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "closing_time_changed", "positions" => {}})
    assert_equal :public, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "standing_bid_changed"})
    assert_equal :public, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "reserve_status_changed"})
    assert_equal :public, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "closing_time_changed"})
    assert_equal :public, RBBB::LiveScheduling::Projector.send(:event_visibility, {"type" => "bidding_closed"})
  end

  def test_coordinator_close_rejects_invalid_effective_at_and_bid_guards_year_9999_overflow
    config = {"currency" => "USD", "opening_minor_units" => 100, "reserve_minor_units" => nil,
      "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 100}],
      "opens_at" => "9999-12-31T22:00:00Z", "closes_at" => "9999-12-31T23:59:59Z",
      "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}
    configs = {"unit-a" => config}
    empty = RBBB::State.empty(RBBB::Configuration.from_h(config)).to_h
    snapshot = {
      "schedule_revision" => 0,
      "units" => {"unit-a" => empty},
      "closing_sets" => [{"group_id" => nil, "member_unit_ids" => ["unit-a"],
        "closes_at" => "9999-12-31T23:59:59Z", "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 120}}]
    }
    coordinator = RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo", configurations: configs,
      snapshot: snapshot, policy: {"minimum_shortening_lead_seconds" => 60})

    bad_close = coordinator.close(
      unit_id: "unit-a",
      command: {"type" => "close_bidding", "command_id" => "bad-close"},
      effective_at: "not-a-timestamp",
      commit_id: "commit-bad-close"
    )
    assert_equal "invalid_request", bad_close.rejection_reason
    assert_empty bad_close.records

    overflow_bid = coordinator.bid(
      unit_id: "unit-a",
      command: {"type" => "place_bid", "command_id" => "overflow-bid", "bidder_id" => "bidder-a", "maximum_minor_units" => 500},
      effective_at: "9999-12-31T23:59:30Z",
      commit_id: "commit-overflow"
    )
    assert_equal "invalid_closing_time", overflow_bid.rejection_reason
    assert_empty overflow_bid.records
  end
end
