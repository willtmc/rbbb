# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/live_scheduling_host"

class LiveSchedulingHostTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @at = "2031-04-17T12:00:00Z"
    vector = JSON.parse(File.readlines(File.expand_path("../../../rfcs/proposals/flexible-live-scheduling/behavior-vectors.jsonl", __dir__)).first)
    @args = {path: File.join(@dir, "auction.sqlite3"), tenant_id: "tenant-demo", auction_id: "auction-demo",
      configurations: vector["unit_setup"].transform_values { |setup| setup["configuration"] },
      snapshot: vector["initial_state"], policy: vector["scheduling_policy"], clock: -> { @at }}
    @intent = vector["steps"].first["action"]["submitted_intent"]
    @host = RBBBExamples::LiveSchedulingHost.new(**@args)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def edit(host = @host, intent = @intent, principal = "operator-demo", permissions = ["schedule", "shorten"])
    host.edit(intent: intent, principal_id: principal, permissions: permissions)
  end

  def copy(value) = RBBB::LiveScheduling.copy(value)

  def test_same_principal_receipt_is_returned_before_clock_or_state_revalidation
    first = edit
    @args[:clock] = -> { raise "clock must not be allocated on replay" }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal first.merge("replayed" => true), edit(reopened)
    assert_equal 1, reopened.receipt_count
    assert_equal 3, reopened.records.size
  end

  def test_principal_and_current_authorization_are_checked_before_receipt_disclosure
    edit
    assert_equal "not_authorized", edit(@host, @intent, "other-operator")["rejection_reason"]
    denied = edit(@host, @intent, "operator-demo", [])
    assert_equal "not_authorized", denied["rejection_reason"]
    assert_empty denied["records"]
    assert_equal 1, @host.receipt_count
  end

  def test_unknown_server_fields_duplicate_keys_and_unicode_are_transport_failures
    malformed = [@intent.merge("effective_at" => @at), @intent.merge("operator_id" => "evil"),
      JSON.generate(@intent).sub('"command_id":', '"command_id":"duplicate","command_id":'),
      JSON.generate(@intent).sub('Invented operational adjustment', '\\ud800')]
    malformed.each { |input| assert_raises(RBBB::LiveScheduling::Intent::Invalid) { edit(@host, input) } }
    assert_equal 0, @host.receipt_count
    assert_empty @host.records
  end

  def test_sealed_auction_keeps_receipts_but_refuses_new_commands
    first = edit
    @host.seal!
    assert_equal first.merge("replayed" => true), edit
    changed = @intent.merge("command_id" => "after-seal")
    assert_equal "auction_sealed", edit(@host, changed)["rejection_reason"]
    assert_equal 2, @host.receipt_count
    assert_equal 3, @host.records.size
  end

  def test_clock_rollback_is_clamped_and_does_not_backdate_a_fresh_command
    edit
    @at = "2031-04-17T11:00:00Z"
    response = @host.bid(unit_id: "unit-c", command: {"type" => "place_bid", "command_id" => "later-bid", "maximum_minor_units" => 5000}, principal_id: "bidder-new")
    assert_nil response["rejection_reason"]
    assert_equal "2031-04-17T12:00:00Z", response["effective_at"]
  end

  def test_outbox_retry_republishes_stable_whole_commit_without_mutating_state
    edit
    before = @host.snapshot
    batches = []
    assert_raises(RuntimeError) { @host.deliver_pending { |batch| batches << batch; raise "consumer crashed" } }
    assert_equal 1, @host.deliver_pending { |batch| batches << batch }
    assert_equal batches[0], batches[1]
    assert_equal [0, 1, 2], batches[0].map { |entry| entry["record_index"] }
    assert_equal 0, @host.deliver_pending { flunk "already acknowledged" }
    assert_equal before, @host.snapshot
    assert_equal 1, @host.receipt_count
  end

  def test_rejection_leaves_domain_history_and_outbox_unchanged
    before = @host.snapshot
    stale = @intent.merge("expected_schedule_revision" => 6)
    assert_equal "stale_revision", edit(@host, stale)["rejection_reason"]
    assert_equal before, @host.snapshot
    assert_empty @host.records
    assert_equal 0, @host.deliver_pending { flunk "rejection has no outbox" }
    assert_equal 1, @host.receipt_count
  end

  def test_two_independent_processes_race_edits_with_one_atomic_winner
    results = race do |host, index|
      edit(host, @intent.merge("command_id" => "edit-#{index}"))
    end
    assert_equal [nil, "stale_revision"], results.map { |r| r["rejection_reason"] }.sort_by(&:to_s)
    assert_equal 8, @host.snapshot["schedule_revision"]
    assert_equal 3, @host.records.size
    assert_equal 2, @host.receipt_count
  end

  def test_two_independent_processes_race_bid_and_edit_at_the_same_time
    @at = "2031-04-17T14:59:30Z"
    results = race do |host, index|
      if index.zero?
        host.bid(unit_id: "unit-a", command: {"type" => "place_bid", "command_id" => "racing-bid", "maximum_minor_units" => 5000}, principal_id: "bidder-new")
      else
        edit(host)
      end
    end
    assert_nil results[0]["rejection_reason"]
    assert_includes [nil, "stale_revision"], results[1]["rejection_reason"]
    snapshot = @host.snapshot
    snapshot["closing_sets"].each { |set| set["member_unit_ids"].each { |id| assert_equal RBBB::Timestamp.parse(set['closes_at']), RBBB::Timestamp.parse(snapshot['units'][id]['closes_at']) } }
    assert_equal 2, @host.receipt_count
  end

  def test_two_independent_processes_race_close_and_edit_without_reopening
    @at = "2031-04-17T15:00:00Z"
    results = race do |host, index|
      if index.zero?
        host.close(group_id: "group-left", command_id: "racing-close", principal_id: "operator-demo", permissions: ["close"])
      else
        changed = copy(@intent)
        changed["resulting_closing_sets"][0]["closes_at"] = "2031-04-17T15:10:00Z"
        edit(host, changed)
      end
    end
    assert_nil results[0]["rejection_reason"]
    assert_includes ["elapsed_or_closed_unit", "stale_revision"], results[1]["rejection_reason"]
    %w[unit-a unit-b].each { |id| assert_equal "closed", @host.snapshot["units"][id]["status"] }
  end

  def test_process_kill_before_commit_rolls_back_state_receipt_and_outbox
    before = @host.snapshot
    kill_at(:before_commit) { |host| edit(host) }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal before, reopened.snapshot
    assert_equal 0, reopened.receipt_count
    assert_empty reopened.records
    assert_equal 0, reopened.deliver_pending { flunk "uncommitted delivery" }
    assert_nil edit(reopened)["rejection_reason"]
    assert_equal 1, reopened.receipt_count
  end

  def test_process_kill_after_commit_preserves_complete_sealed_receipt_and_outbox
    kill_at(:after_commit) { |host| edit(host) }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal 8, reopened.snapshot["schedule_revision"]
    assert_equal 1, reopened.receipt_count
    assert_equal 3, reopened.records.size
    reopened.seal!
    @args[:clock] = -> { raise "replay must not allocate time" }
    restored = RBBBExamples::LiveSchedulingHost.new(**@args)
    response = edit(restored)
    assert response["replayed"]
    assert_nil response["rejection_reason"]
    assert_equal restored.records, response["records"]
    assert_equal 1, restored.deliver_pending { |batch| assert_equal response["records"], batch.map { |entry| entry["record"] } }
    assert_equal 0, restored.deliver_pending { flunk "duplicate delivery" }
  end

  def test_process_kill_before_outbox_ack_redelivers_identical_batch
    edit
    before = @host.snapshot
    delivered_path = File.join(@dir, "delivered.json")
    kill_at(:before_delivery_ack) do |host|
      host.deliver_pending { |batch| File.write(delivered_path, JSON.generate(batch)) }
    end
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    delivered = JSON.parse(File.read(delivered_path))
    assert_equal 1, reopened.deliver_pending { |batch| assert_equal delivered, batch }
    assert_equal 0, reopened.deliver_pending { flunk "already acknowledged" }
    assert_equal before, reopened.snapshot
    assert_equal 1, reopened.receipt_count
  end

  def test_sealed_database_archive_restore_preserves_receipts_and_pending_delivery
    accepted = edit
    rejected_intent = @intent.merge("command_id" => "retained-rejection", "expected_schedule_revision" => 6)
    rejected = edit(@host, rejected_intent)
    assert_equal "stale_revision", rejected["rejection_reason"]
    @host.seal!
    archived_state = @host.snapshot
    archive_path = File.join(@dir, "sealed-archive.sqlite3")
    # No connections remain open: copy the complete sealed embedded database,
    # not a snapshot-only export that would lose receipt/outbox identity.
    FileUtils.cp(@args[:path], archive_path)
    restored = RBBBExamples::LiveSchedulingHost.new(**@args.merge(path: archive_path,
      clock: -> { raise "restored receipt replay must not consult clock" }))
    assert_equal accepted.merge("replayed" => true), edit(restored)
    assert_equal rejected.merge("replayed" => true), edit(restored, rejected_intent)
    assert_equal "not_authorized", edit(restored, @intent, "another-operator")["rejection_reason"]
    assert_equal "not_authorized", edit(restored, @intent, "operator-demo", [])["rejection_reason"]
    changed = @intent.merge("reason" => "Different synthetic intent")
    assert_equal "command_id_reused", edit(restored, changed)["rejection_reason"]
    assert_equal 1, restored.deliver_pending { |batch| assert_equal accepted["records"], batch.map { |entry| entry["record"] } }
    assert_equal 0, restored.deliver_pending { flunk "restored acknowledgment lost" }
    assert_equal archived_state, restored.snapshot
    assert_equal 2, restored.receipt_count
    # Restoring a sealed archive must not reopen mutation.
    restored = RBBBExamples::LiveSchedulingHost.new(**@args.merge(path: archive_path))
    assert_equal "auction_sealed", edit(restored, @intent.merge("command_id" => "new-after-restore"))["rejection_reason"]
    assert_equal archived_state, restored.snapshot
    assert_equal accepted["records"], restored.records
    # A restored copy's delivery acknowledgment cannot change the archive source.
    assert_equal 1, @host.deliver_pending { |batch| assert_equal accepted["records"], batch.map { |entry| entry["record"] } }
  end

  # Signal readiness only at the selected persistence boundary, then let the
  # parent SIGKILL the process: no Ruby exception/ensure rollback can run.
  def kill_at(hook)
    ready_read, ready_write = IO.pipe
    pid = fork do
      ready_read.close
      host = RBBBExamples::LiveSchedulingHost.new(**@args)
      host.define_singleton_method(hook) do |*_args|
        ready_write.write("ready")
        ready_write.flush
        sleep
      end
      yield host
      exit! 1
    end
    ready_write.close
    assert IO.select([ready_read], nil, nil, 10), "child never reached #{hook}"
    assert_equal "ready", ready_read.read(5), "child exited before #{hook}"
    Process.kill("KILL", pid)
    Process.wait(pid)
    assert_equal Signal.list.fetch("KILL"), $?.termsig
    pid = nil
  ensure
    if pid
      Process.kill("KILL", pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
    ready_read&.close unless ready_read&.closed?
    ready_write&.close unless ready_write&.closed?
  end

  def race
    go_read, go_write = IO.pipe
    children = 2.times.map do |index|
      fork do
        go_write.close
        go_read.read(1)
        host = RBBBExamples::LiveSchedulingHost.new(**@args)
        result = yield host, index
        File.write(File.join(@dir, "result-#{index}.json"), JSON.generate(result))
        exit! 0
      rescue Exception => e
        File.write(File.join(@dir, "result-#{index}.json"), JSON.generate("error" => e.full_message))
        exit! 1
      end
    end
    go_read.close
    go_write.write("go"); go_write.close
    children.each do |pid|
      Process.wait(pid)
      assert $?.success?, "race child failed: #{Dir.glob(File.join(@dir, 'result-*.json')).map { |path| File.read(path) }.join}"
    end
    2.times.map { |index| JSON.parse(File.read(File.join(@dir, "result-#{index}.json"))) }
  ensure
    go_read&.close unless go_read&.closed?
    go_write&.close unless go_write&.closed?
  end
end
