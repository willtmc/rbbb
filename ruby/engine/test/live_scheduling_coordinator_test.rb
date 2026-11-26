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
end
