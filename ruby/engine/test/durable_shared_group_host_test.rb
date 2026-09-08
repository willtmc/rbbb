# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/durable_shared_group_host"

class DurableSharedGroupHostTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("rbbb-durable-")
    @path = File.join(@directory, "group.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def configurations
    %w[lot-12 lot-47].to_h do |id|
      [id, {currency: "USD", opening_minor_units: 1000,
        increments: [{from_minor_units: 0, amount_minor_units: 100}],
        opens_at: "2030-01-01T12:00:00Z", closes_at: "2030-01-01T13:00:00Z"}]
    end
  end

  def clock
    {group_id: "group-a", unit_ids: %w[lot-12 lot-47],
     closes_at: "2030-01-01T13:00:00Z", quiet_period_seconds: 180}
  end

  def host(klass = RBBBExamples::DurableSharedGroupHost)
    klass.new(path: @path, configurations: configurations, clock: clock)
  end

  def request(id: "bid-a", unit: "lot-12", revision: 0, at: "2030-01-01T12:59:00Z", maximum: 5000)
    {unit_id: unit, expected_revision: revision, command: {command_id: id,
      type: "place_bid", bidder_id: "bidder-a", maximum_minor_units: maximum, effective_at: at}}
  end

  def test_restart_recovers_deadlines_events_and_exact_retry_receipt
    first = host.submit(**request)
    recovered = host
    retried = recovered.submit(**request)
    assert_equal first.clock, retried.clock
    assert_equal first.decision.events.map(&:to_h), retried.decision.events.map(&:to_h)
    later = recovered.submit(**request(id: "bid-b", unit: "lot-47", revision: 1, at: "2030-01-01T13:01:00Z"))
    assert later.decision.accepted?
    assert_equal ["2030-01-01T13:04:00Z"], host.public_view["units"].values.map { |v| v["closes_at"] }.uniq
    assert_equal first.clock, host.submit(**request).clock
    assert_equal 0, File.stat(@path).mode & 0o077
  end

  def test_process_death_before_commit_rolls_back_bid_clock_and_receipt
    host
    crashing = Class.new(RBBBExamples::DurableSharedGroupHost) do
      private
      def before_commit(_db)
        Process.exit!(73)
      end
    end
    pid = fork { host(crashing).submit(**request) }
    _, status = Process.wait2(pid)
    assert_equal 73, status.exitstatus
    assert_equal 0, host.public_view["clock"]["revision"]
    assert_equal 0, host.public_view["units"]["lot-12"]["version"]
    assert host.submit(**request).decision.accepted?
    assert_equal 1, host.public_view["units"]["lot-12"]["version"]
  end

  def test_process_death_after_commit_allows_retry_without_duplicate_bid
    host
    pid = fork do
      host.submit(**request)
      Process.exit!(74)
    end
    _, status = Process.wait2(pid)
    assert_equal 74, status.exitstatus
    assert host.submit(**request).decision.accepted?
    assert_equal 1, host.public_view["units"]["lot-12"]["version"]
    db = SQLite3::Database.new(@path)
    assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM commits")
  ensure
    db&.close
  end

  def test_separate_processes_retry_same_request_once
    host
    pids = 4.times.map do
      fork do
        host.submit(**request)
        Process.exit!(0)
      end
    end
    pids.each { |pid| assert Process.wait2(pid).last.success? }
    assert_equal 1, host.public_view["units"]["lot-12"]["version"]
    assert_equal 1, host.public_view["clock"]["revision"]
  end

  def test_conflicting_retry_and_configuration_change_do_not_overwrite_history
    host.submit(**request)
    before = host.public_view
    assert_raises(ArgumentError) { host.submit(**request(unit: "lot-47")) }
    assert_raises(ArgumentError) do
      RBBBExamples::DurableSharedGroupHost.new(path: @path, configurations: configurations,
        clock: clock.merge(quiet_period_seconds: 120))
    end
    assert_equal before, host.public_view
  end

  def test_rejected_bid_receipt_survives_restart_without_clock_change
    first = host.submit(**request(maximum: 1))
    assert first.decision.rejected?
    assert_equal first.decision.rejection, host.submit(**request(maximum: 1)).decision.rejection
    assert_equal 0, host.public_view["clock"]["revision"]
  end

  def test_replay_mismatch_is_refused_instead_of_silently_repricing
    host.submit(**request)
    db = SQLite3::Database.new(@path)
    db.execute("UPDATE commits SET result = '{}' WHERE command_id = 'bid-a'")
    assert_raises(RBBB::InvalidState) { host.public_view }
  ensure
    db&.close
  end
  def test_competing_processes_cannot_commit_against_the_same_clock_revision
    host
    pids = %w[lot-12 lot-47].map do |unit|
      fork do
        host.submit(**request(id: unit, unit: unit))
        Process.exit!(0)
      rescue RBBB::InvalidState
        Process.exit!(75)
      end
    end
    assert_equal [0, 75], pids.map { |pid| Process.wait2(pid).last.exitstatus }.sort
    assert_equal 1, host.public_view["units"].values.sum { |v| v["version"] }
    assert_equal 1, host.public_view["clock"]["revision"]
  end

  def test_proxy_increase_after_restart_does_not_extend_deadline
    host.submit(**request)
    receipt = host.submit(**request(id: "increase", revision: 1,
      at: "2030-01-01T13:01:00Z", maximum: 6000))
    assert receipt.decision.accepted?
    assert_equal "2030-01-01T13:02:00Z", host.public_view["clock"]["closes_at"]
    assert_equal 1, host.public_view["clock"]["revision"]
  end

end
