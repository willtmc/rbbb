# frozen_string_literal: true

require_relative "test_helper"
require "rbbb/live_scheduling"

class LiveSchedulingLimitsTest < Minitest::Test
  def setup
    @config = {"currency" => "USD", "opening_minor_units" => 1000,
      "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 100}],
      "opens_at" => "2031-04-17T10:00:00Z", "closes_at" => "2031-04-17T15:00:00Z", "extension" => nil}
  end

  def coordinator(count, profile: RBBB::LiveScheduling::PROFILE)
    ids = count.times.map { |i| format("unit-%04d", i) }
    state = RBBB::State.empty(RBBB::Configuration.from_h(@config)).to_h
    sets = ids.map { |id| {"group_id" => nil, "member_unit_ids" => [id], "closes_at" => @config["closes_at"], "extension" => nil} }
    snapshot = {"schedule_revision" => 0, "closing_sets" => sets, "units" => ids.to_h { |id| [id, state] }}
    RBBB::LiveScheduling::Coordinator.new(auction_id: "auction-demo", configurations: ids.to_h { |id| [id, @config] },
      snapshot: snapshot, policy: {"minimum_shortening_lead_seconds" => 180}, profile: profile)
  end

  def intent(core)
    {"capability" => RBBB::LiveScheduling::CAPABILITY, "type" => "reconfigure_closing_groups",
      "command_id" => "large-merge", "auction_id" => "auction-demo", "expected_schedule_revision" => 0,
      "expected_units" => core.snapshot["units"].map { |id, unit| {"unit_id" => id, "version" => unit["version"]} },
      "reason" => "Synthetic resource boundary", "allow_shortening" => false,
      "resulting_closing_sets" => [{"group_id" => "large-group", "member_unit_ids" => core.snapshot['units'].keys,
        "closes_at" => @config['closes_at'], "extension" => nil}], "retired_group_ids" => []}
  end

  def decide(core, submission)
    core.edit(intent: submission, principal_id: "operator-demo", permissions: ["schedule"],
      effective_at: "2031-04-17T12:00:00Z", commit_id: "synthetic-commit")
  end

  def test_fls_19_executes_a_full_4096_unit_merge_and_split
    core = coordinator(4096)
    merge = decide(core, intent(core))
    assert_nil merge.rejection_reason
    assert_equal 4096, merge.records[1]['unit_versions'].size
    assert merge.state['units'].values.all? { |unit| unit['version'] == 1 }
    next_core = RBBB::LiveScheduling::Coordinator.new(auction_id: core.auction_id, configurations: core.configurations,
      snapshot: merge.state, policy: core.policy)
    split_intent = intent(next_core).merge('command_id' => 'large-split', 'expected_schedule_revision' => 1,
      'resulting_closing_sets' => core.snapshot['closing_sets'], 'retired_group_ids' => ['large-group'])
    split = decide(next_core, split_intent)
    assert_nil split.rejection_reason
    assert_equal 4096, split.state['closing_sets'].size
    assert split.state['units'].values.all? { |unit| unit['version'] == 2 }
  end

  def test_fls_20_discovery_rejects_a_boundary_plus_one_without_partial_effects
    core = coordinator(4096, profile: RBBB::LiveScheduling::PROFILE.merge('affected_units' => 4095))
    before = Marshal.dump(core.snapshot)
    result = decide(core, intent(core))
    assert_equal 'resource_limit_exceeded', result.rejection_reason
    assert_empty result.records
    assert_equal before, Marshal.dump(core.snapshot)
    core = coordinator(4097)
    assert_equal 'invalid_request', decide(core, intent(core)).rejection_reason
  end

  def test_raw_body_limit_accepts_exactly_the_limit_and_rejects_plus_one_before_parse
    raw = JSON.generate(intent(coordinator(1)))
    profile = RBBB::LiveScheduling::PROFILE.merge('request_bytes' => raw.bytesize)
    assert RBBB::LiveScheduling::Intent.parse(raw, profile: profile)
    assert_raises(RBBB::LiveScheduling::Intent::Invalid) { RBBB::LiveScheduling::Intent.parse(raw + ' ', profile: profile) }
  end

  def test_encoded_batch_limit_rejects_without_state_changes
    core = coordinator(2)
    submission = intent(core)
    result = decide(core, submission)
    size = RBBB::LiveScheduling.encoded_batch_size(result.records, 'synthetic-commit')
    exact = coordinator(2, profile: RBBB::LiveScheduling::PROFILE.merge('batch_bytes' => size))
    assert_nil decide(exact, submission).rejection_reason
    small = coordinator(2, profile: RBBB::LiveScheduling::PROFILE.merge('batch_bytes' => size - 1))
    rejected = decide(small, submission)
    assert_equal 'resource_limit_exceeded', rejected.rejection_reason
    assert_equal small.snapshot, rejected.state
    assert_empty rejected.records
  end

  def test_projector_refuses_partial_manual_and_automatic_commits
    core = coordinator(2)
    edit = decide(core, intent(core))
    assert_raises(RBBB::InvalidState) do
      RBBB::LiveScheduling::Projector.apply(snapshot: core.snapshot, configurations: core.configurations, records: edit.records.drop(1))
    end
    extended_sets = edit.state['closing_sets'].map { |set| set.merge('extension' => {'trigger_window_seconds' => 120, 'duration_seconds' => 180}) }
    next_core = RBBB::LiveScheduling::Coordinator.new(auction_id: core.auction_id, configurations: core.configurations,
      snapshot: edit.state.merge('closing_sets' => extended_sets), policy: core.policy)
    bid = next_core.bid(unit_id: 'unit-0000', command: {'type' => 'place_bid', 'command_id' => 'late-bid',
      'bidder_id' => 'synthetic-bidder', 'maximum_minor_units' => 3000}, effective_at: '2031-04-17T14:59:00Z', commit_id: 'bid-commit')
    assert_nil bid.rejection_reason
    [bid.records.select { |record| record.key?('unit_id') }, bid.records.reject { |record| record.key?('unit_id') }].each do |partial|
      assert_raises(RBBB::InvalidState) do
        RBBB::LiveScheduling::Projector.apply(snapshot: next_core.snapshot, configurations: next_core.configurations, records: partial)
      end
    end
  end

  def test_no_change_and_exhaustion_cannot_advance_revision
    core = coordinator(1)
    unchanged = intent(core).merge('resulting_closing_sets' => core.snapshot['closing_sets'])
    assert_equal 'no_change', decide(core, unchanged).rejection_reason
    snapshot = RBBB::LiveScheduling.copy(core.snapshot)
    snapshot['schedule_revision'] = RBBB::MAX_SAFE_INTEGER
    exhausted = RBBB::LiveScheduling::Coordinator.new(auction_id: core.auction_id, configurations: core.configurations,
      snapshot: snapshot, policy: core.policy)
    submission = intent(exhausted).merge('expected_schedule_revision' => RBBB::MAX_SAFE_INTEGER)
    assert_equal 'version_exhausted', decide(exhausted, submission).rejection_reason
  end
end
