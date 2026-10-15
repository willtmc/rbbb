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

  def registration(id = "register-command", unit = "unit-new")
    {"type" => "register_unit", "command_id" => id, "auction_id" => "auction-demo",
      "unit_id" => unit, "expected_schedule_revision" => 7,
      "configuration" => copy(@args[:configurations]["unit-c"]).merge("reserve_minor_units" => nil), "reason" => "Synthetic registration"}
  end

  def register(host = @host, intent = registration, principal = "operator-demo", permissions = ["register"])
    host.register_unit(intent: intent, principal_id: principal, permissions: permissions)
  end

  def test_registration_reopen_preserves_registry_receipt_and_new_unit_bid
    response = register
    assert_nil response["rejection_reason"]
    before = @host.snapshot
    assert_equal 0, before["units"]["unit-new"]["version"]
    assert_nil before["units"]["unit-new"]["last_effective_at"]
    assert_equal 8, before["schedule_revision"]
    assert_equal 2, response["records"].size
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal response.merge("replayed" => true), register(reopened)
    assert_equal @host.configurations, reopened.configurations
    assert_equal RBBB::LiveScheduling::Intent.normalize_registration(registration)["configuration"], reopened.configurations["unit-new"]
    denied = register(reopened, registration, "other-operator")
    assert_equal "not_authorized", denied["rejection_reason"]
    assert_empty denied["records"]
    assert_equal "not_authorized", register(reopened, registration, "operator-demo", [])["rejection_reason"]
    assert_equal "command_id_reused", register(reopened, registration.merge("reason" => "Changed"))["rejection_reason"]
    assert_equal before, reopened.snapshot
    assert_nil reopened.bid(unit_id: "unit-new", command: {"type" => "place_bid", "command_id" => "new-unit-bid", "maximum_minor_units" => 5000}, principal_id: "bidder-new")["rejection_reason"]
    assert_equal 1, reopened.snapshot["units"]["unit-new"]["version"]
    assert RBBBExamples::LiveSchedulingHost.new(**@args).configurations.key?("unit-new")
    changed = @args.merge(configurations: copy(@args[:configurations]))
    changed[:configurations]["unit-c"]["reserve_minor_units"] = 123
    assert_raises(ArgumentError) { RBBBExamples::LiveSchedulingHost.new(**changed) }
  end

  def test_registration_rejection_and_transport_failure_preserve_domain_registry
    before, configs = @host.snapshot, @host.configurations
    denied = register(@host, registration, "operator-demo", [])
    assert_equal "not_authorized", denied["rejection_reason"]
    assert_equal denied.merge("replayed" => true), register
    assert_equal before, @host.snapshot
    assert_equal configs, @host.configurations
    assert_empty @host.records
    assert_equal 0, @host.deliver_pending { flunk "rejected registration delivery" }
    assert_raises(ArgumentError) { register(@host, registration("invalid").merge("operator_id" => "spoof")) }
    assert_equal 1, @host.receipt_count
  end

  def test_registration_transaction_failure_and_process_kill_recovery
    before, configs = @host.snapshot, @host.configurations
    failing = Class.new(RBBBExamples::LiveSchedulingHost) do
      private
      def before_commit(_db) = raise("synthetic registration failure")
    end.new(**@args)
    assert_raises(RuntimeError) { register(failing) }
    kill_at(:before_commit) { |host| register(host) }
    assert_equal before, @host.snapshot
    assert_equal configs, @host.configurations
    assert_equal 0, @host.receipt_count
    assert_empty @host.records
    assert_equal 0, @host.deliver_pending { flunk "uncommitted registration delivery" }
    kill_at(:after_commit) { |host| register(host) }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    response = register(reopened)
    assert response["replayed"]
    assert_equal 1, reopened.receipt_count
    assert_equal 0, reopened.snapshot["units"]["unit-new"]["version"]
    assert_nil reopened.snapshot["units"]["unit-new"]["last_effective_at"]
    assert reopened.configurations.key?("unit-new")
    assert_equal 1, reopened.deliver_pending { |batch| assert_equal response["records"], batch.map { |item| item["record"] } }
  end

  def test_registration_outbox_crash_and_sealed_restore_preserve_creation_identity
    response = register
    delivered_path = File.join(@dir, "registration-delivered.json")
    kill_at(:before_delivery_ack) do |host|
      host.deliver_pending { |batch| File.write(delivered_path, JSON.generate(batch)) }
    end
    @host.seal!
    archived = File.join(@dir, "registration-archive.sqlite3")
    FileUtils.cp(@args[:path], archived)
    restored = RBBBExamples::LiveSchedulingHost.new(**@args.merge(path: archived,
      clock: -> { raise "restored replay must not allocate time" }))
    assert_equal response.merge("replayed" => true), register(restored)
    assert_equal @host.snapshot, restored.snapshot
    assert_equal @host.configurations, restored.configurations
    delivered = JSON.parse(File.read(delivered_path))
    assert_equal 1, restored.deliver_pending { |batch| assert_equal delivered, batch }
    assert_equal 0, restored.deliver_pending { flunk "duplicate acknowledged batch" }
    restored = RBBBExamples::LiveSchedulingHost.new(**@args.merge(path: archived))
    assert_equal "auction_sealed", register(restored, registration("sealed-new", "unit-other").merge("expected_schedule_revision" => 8))["rejection_reason"]
    assert_equal @host.snapshot, restored.snapshot
    assert_equal @host.configurations, restored.configurations
    assert_equal 1, @host.deliver_pending { |batch| assert_equal delivered, batch }
  end

  def test_independent_registration_race_has_one_complete_winner
    results = race { |host, index| register(host, registration("racing-register-#{index}")) }
    assert_equal [nil, "stale_revision"], results.map { |r| r["rejection_reason"] }.sort_by(&:to_s)
    assert_equal 8, @host.snapshot["schedule_revision"]
    assert_equal 2, @host.receipt_count
    assert_equal 2, @host.records.size
    assert_equal 4, @host.configurations.size
    assert_equal 0, @host.snapshot["units"]["unit-new"]["version"]
  end

  # REG-10/21: both rejected and accepted receipts survive sealing and copying;
  # replay is not a new decision and must not allocate an ordered timestamp.
  def test_registration_rejected_receipt_replays_after_seal_and_archive_restore
    rejected_intent = registration("retained-conflict", "unit-a")
    rejected = register(@host, rejected_intent)
    assert_equal "unit_id_conflict", rejected["rejection_reason"]
    accepted = register
    @host.seal!
    before, configs, records = @host.snapshot, @host.configurations, @host.records
    replay_args = @args.merge(clock: -> { raise "retained replay allocated time" })
    assert_equal rejected.merge("replayed" => true), register(RBBBExamples::LiveSchedulingHost.new(**replay_args), rejected_intent)
    archived = File.join(@dir, "retained-rejection.sqlite3")
    FileUtils.cp(@args[:path], archived)
    restored = RBBBExamples::LiveSchedulingHost.new(**replay_args.merge(path: archived))
    assert_equal rejected.merge("replayed" => true), register(restored, rejected_intent)
    assert_equal accepted.merge("replayed" => true), register(restored)
    assert_equal before, restored.snapshot
    assert_equal configs, restored.configurations
    assert_equal records, restored.records
    assert_equal 2, restored.receipt_count
    assert_equal 1, restored.deliver_pending { |batch| assert_equal accepted["records"], batch.map { |item| item["record"] } }
    assert_equal 0, restored.deliver_pending { flunk "duplicate acknowledged creation" }
    writable_clock = RBBBExamples::LiveSchedulingHost.new(**@args.merge(path: archived))
    sealed = register(writable_clock, registration("sealed-fresh", "unit-other").merge("expected_schedule_revision" => 8))
    assert_equal "auction_sealed", sealed["rejection_reason"]
    assert_equal before, writable_clock.snapshot
    assert_equal configs, writable_clock.configurations
    assert_equal records, writable_clock.records
    assert_equal 3, writable_clock.receipt_count
  end

  # REG-12: the stale race loser cannot create the same identity with a fresh
  # key and current revision, nor replace the original retained rejection.
  def test_registration_race_fresh_key_conflict_preserves_winner_and_loser_receipts
    results = race { |host, index| register(host, registration("fresh-conflict-race-#{index}")) }
    loser_index = results.index { |result| result["rejection_reason"] == "stale_revision" }
    refute_nil loser_index
    before, configs, records = @host.snapshot, @host.configurations, @host.records
    intent = registration("fresh-conflict").merge("expected_schedule_revision" => 8)
    rejected = register(@host, intent)
    assert_equal "unit_id_conflict", rejected["rejection_reason"]
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args.merge(clock: -> { raise "replay allocated time" }))
    assert_equal rejected.merge("replayed" => true), register(reopened, intent)
    assert_equal results[loser_index].merge("replayed" => true), register(reopened, registration("fresh-conflict-race-#{loser_index}"))
    assert_equal before, reopened.snapshot
    assert_equal configs, reopened.configurations
    assert_equal records, reopened.records
    assert_equal 3, reopened.receipt_count
    assert_equal 1, reopened.deliver_pending { |batch| assert_equal records, batch.map { |item| item["record"] } }
  end

  def database_rows(path = @args[:path])
    db = SQLite3::Database.new(path)
    %w[auctions receipts commits outbox].to_h { |table| [table, db.execute("SELECT * FROM #{table} ORDER BY rowid")] }
  ensure
    db&.close
  end

  def test_registration_host_exact_admission_boundaries_have_no_overflow_receipt
    raw = JSON.generate(registration)
    profile = RBBB::LiveScheduling::PROFILE.merge("request_bytes" => raw.bytesize, "depth" => 4)
    args = @args.merge(path: File.join(@dir, "admission.sqlite3"), profile: profile)
    host = RBBBExamples::LiveSchedulingHost.new(**args)
    before = database_rows(args[:path])
    assert_raises(ArgumentError) { register(host, raw + " ") }
    assert_equal before, database_rows(args[:path])
    assert_nil register(host, raw)["rejection_reason"]
    assert_equal 1, host.receipt_count
    shallow_args = @args.merge(path: File.join(@dir, "depth.sqlite3"), profile: profile.merge("depth" => 3))
    shallow = RBBBExamples::LiveSchedulingHost.new(**shallow_args)
    before = database_rows(shallow_args[:path])
    assert_raises(ArgumentError) { register(shallow, raw) }
    assert_equal before, database_rows(shallow_args[:path])
  end

  def test_registration_host_batch_boundary_and_ceiling_rejections_are_retained
    fixed = Class.new(RBBBExamples::LiveSchedulingHost) do
      private
      def next_commit_id = "synthetic-fixed-commit"
    end
    oracle = fixed.new(**@args).register_unit(intent: registration, principal_id: "operator-demo", permissions: ["register"])
    size = RBBB::LiveScheduling.encoded_batch_size(oracle["records"], oracle["commit_id"])
    [size, size - 1].each do |limit|
      args = @args.merge(path: File.join(@dir, "batch-#{limit}.sqlite3"),
        profile: RBBB::LiveScheduling::PROFILE.merge("batch_bytes" => limit))
      host = fixed.new(**args)
      before, configs = host.snapshot, host.configurations
      response = register(host)
      if limit == size
        assert_nil response["rejection_reason"]
        assert_equal oracle["records"], response["records"]
      else
        assert_equal "resource_limit_exceeded", response["rejection_reason"]
        assert_equal before, host.snapshot
        assert_equal configs, host.configurations
        assert_empty host.records
        assert_equal 0, host.deliver_pending { flunk "overflow published" }
      end
      assert_equal 1, host.receipt_count
      stored = database_rows(args[:path])
      reopened = fixed.new(**args.merge(clock: -> { raise "boundary replay allocated time" }))
      assert_equal response.merge("replayed" => true), register(reopened)
      assert_equal stored, database_rows(args[:path])
      row = stored["auctions"].first
      assert_equal @at, row[6]
      assert_equal 1, row[7]
    end
    state = copy(@args[:snapshot]).merge("schedule_revision" => RBBB::MAX_SAFE_INTEGER)
    args = @args.merge(path: File.join(@dir, "ceiling.sqlite3"), snapshot: state)
    host = fixed.new(**args)
    before = host.snapshot
    intent = registration.merge("expected_schedule_revision" => RBBB::MAX_SAFE_INTEGER)
    response = register(host, intent)
    assert_equal "version_exhausted", response["rejection_reason"]
    assert_equal before, host.snapshot
    assert_equal @args[:configurations], host.configurations
    assert_empty host.records
    assert_equal 1, host.receipt_count
    stored = database_rows(args[:path])
    reopened = fixed.new(**args.merge(clock: -> { raise "ceiling replay allocated time" }))
    assert_equal response.merge("replayed" => true), register(reopened, intent)
    assert_equal stored, database_rows(args[:path])
  end

  def test_registration_incomplete_archives_refuse_reopen_and_existing_host_mutation
    register
    register(@host, registration("retained-conflict", "unit-a").merge("expected_schedule_revision" => 8))
    @host.seal!
    corruptions = {
      "registry" => lambda { |db|
        encoded = db.get_first_value("SELECT configuration FROM auctions")
        document = JSON.parse(encoded)
        document["configurations"].delete("unit-new")
        db.execute("UPDATE auctions SET configuration = ?", [JSON.generate(document)])
      },
      "accepted-receipt" => ->(db) { db.execute("DELETE FROM receipts WHERE command = 'register-command'") },
      "rejected-receipt" => ->(db) { db.execute("DELETE FROM receipts WHERE command = 'retained-conflict'") },
      "unsealed-rejected-receipt" => lambda { |db|
        db.execute("UPDATE auctions SET sealed = 0")
        db.execute("DELETE FROM receipts WHERE command = 'retained-conflict'")
      },
      "commits" => ->(db) { db.execute("DELETE FROM commits") },
      "outbox" => ->(db) { db.execute("DELETE FROM outbox WHERE record_index = 0") }
    }
    corruptions.each do |name, corrupt|
      path = File.join(@dir, "incomplete-#{name}.sqlite3")
      FileUtils.cp(@args[:path], path)
      args = @args.merge(path: path, clock: -> { raise "incomplete archive allocated time" })
      existing = RBBBExamples::LiveSchedulingHost.new(**args)
      db = SQLite3::Database.new(path)
      begin
        corrupt.call(db)
      ensure
        db.close
      end
      before = database_rows(path)
      assert_raises(RBBB::InvalidState, name) { RBBBExamples::LiveSchedulingHost.new(**args) }
      assert_raises(RBBB::InvalidState, name) { register(existing) }
      assert_raises(RBBB::InvalidState, name) { register(existing, registration("new-after-loss", "unit-other")) }
      assert_equal before, database_rows(path), name
    end
  end

  # REG-18: inconsistent replay inputs must reject without mutating either
  # registry. Persistent consumer cursors remain a separate adapter obligation.
  def test_registration_projector_rejects_occupied_identity_and_revision_gap
    before, configs = @host.snapshot, @host.configurations
    response = register
    occupied = copy(before)
    occupied["units"]["unit-new"] = copy(@host.snapshot["units"]["unit-new"])
    occupied_configs = configs.merge("unit-new" => copy(@host.configurations["unit-new"]))
    gap = copy(before)
    gap["schedule_revision"] -= 1
    [[occupied, occupied_configs], [gap, configs]].each do |snapshot, configurations|
      original_snapshot, original_configurations = copy(snapshot), copy(configurations)
      assert_raises(RBBB::InvalidState) do
        RBBB::LiveScheduling::Projector.apply_commit(snapshot: snapshot, configurations: configurations,
          records: response["records"], policy: @args[:policy], auction_id: @args[:auction_id])
      end
      assert_equal original_snapshot, snapshot
      assert_equal original_configurations, configurations
    end
  end

  def test_registration_projector_requires_exact_whole_creation_and_returns_both_registries
    before, configs = @host.snapshot, @host.configurations
    response = register
    records = response["records"]
    replay = ->(batch) { RBBB::LiveScheduling::Projector.apply_commit(snapshot: before,
      configurations: configs, records: batch, policy: @args[:policy], auction_id: @args[:auction_id]) }
    result = replay.call(records)
    assert_equal @host.snapshot, result["snapshot"]
    assert_equal @host.configurations, result["configurations"]
    assert_nil result["snapshot"]["units"]["unit-new"]["last_effective_at"]
    assert_equal 0, result["snapshot"]["units"]["unit-new"]["version"]
    assert_equal 3, configs.size
    refute before["units"].key?("unit-new")
    bad_batches = [records.reverse, [records[0]], [records[1]]]
    %w[state configuration operator_id reason unit_id auction_id commit_id effective_at visibility].each do |key|
      changed = copy(records)
      changed[0][key] = key == "state" ? changed[0][key].merge("version" => 1) : ""
      bad_batches << changed
    end
    changed = copy(records)
    changed[0]["state"]["last_effective_at"] = changed[0]["effective_at"]
    bad_batches << changed
    changed = copy(records)
    changed[1]["unit_versions"][0]["version"] = 1
    bad_batches << changed
    changed = copy(records)
    changed[0]["unknown"] = "extra"
    bad_batches << changed
    bad_batches.each { |batch| assert_raises(RBBB::InvalidState) { replay.call(batch) } }
    assert_raises(RBBB::InvalidState) { RBBB::LiveScheduling::Projector.apply(snapshot: before, configurations: configs, records: records) }
    assert_equal 3, configs.size
    refute before["units"].key?("unit-new")
  end

  # REG-01: compare the entire baseline state and pre-existing aggregate,
  # not just the new unit's version and a receipt count.
  def test_registration_exact_creation_oracle_preserves_existing_bids
    before, configs = @host.snapshot, @host.configurations
    intent = registration
    response = register(@host, intent)
    configuration = RBBB::LiveScheduling::Intent.normalize_registration(intent)["configuration"]
    empty = RBBB::Engine.new(RBBB::Configuration.from_h(configuration)).initial_state.to_h
    expected = copy(before)
    expected["schedule_revision"] += 1
    expected["units"]["unit-new"] = empty
    expected["closing_sets"] << {"group_id" => nil, "member_unit_ids" => ["unit-new"],
      "closes_at" => configuration["closes_at"], "extension" => configuration["extension"]}
    assert_equal expected, @host.snapshot
    assert_equal configs.merge("unit-new" => configuration), @host.configurations
    assert_equal %w[bidding_unit_registered closing_configuration_changed], response["records"].map { |r| r["type"] }
    assert_equal empty, response["records"][0]["state"]
    assert_equal configuration, response["records"][0]["configuration"]
    assert_equal 1, @host.receipt_count
    assert_equal response["records"], @host.records
    assert_equal 1, @host.deliver_pending { |batch| assert_equal response["records"], batch.map { |r| r["record"] } }
  end

  # REG-03/04: replay cannot consult a new clock or overwrite the receipt.
  def test_registration_late_retry_and_changed_intents_do_not_allocate_decisions
    response = register
    before, configs, records = @host.snapshot, @host.configurations, @host.records
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args.merge(clock: -> { raise "replay allocated time" }))
    assert_equal response.merge("replayed" => true), register(reopened)
    [registration.merge("unit_id" => "unit-other"), registration.merge("reason" => "Different"),
      registration.merge("configuration" => registration["configuration"].merge("reserve_minor_units" => 6000))].each do |changed|
      assert_equal "command_id_reused", register(reopened, changed)["rejection_reason"]
    end
    assert_equal response.merge("replayed" => true), register(reopened)
    assert_equal before, reopened.snapshot
    assert_equal configs, reopened.configurations
    assert_equal records, reopened.records
    assert_equal 1, reopened.receipt_count
  end

  # REG-06/07/08: precedence and retained rejections leave all domain data intact.
  def test_registration_conflict_stale_and_elapsed_deadline_retention
    before, configs = @host.snapshot, @host.configurations
    conflict = registration("occupied", "unit-a")
    assert_equal "unit_id_conflict", register(@host, conflict)["rejection_reason"]
    stale = registration("stale", "unit-a").merge("expected_schedule_revision" => 6)
    stale["configuration"]["closes_at"] = @at
    rejected = register(@host, stale)
    assert_equal "stale_revision", rejected["rejection_reason"]
    [@at, "2031-04-17T11:59:59Z"].each_with_index do |deadline, index|
      elapsed = registration("elapsed-#{index}")
      elapsed["configuration"]["closes_at"] = deadline
      assert_equal "invalid_schedule", register(@host, elapsed)["rejection_reason"]
    end
    assert_equal before, @host.snapshot
    assert_equal configs, @host.configurations
    assert_empty @host.records
    assert_equal 0, @host.deliver_pending { flunk "rejection published" }
    assert_nil register(@host, registration("advance"))["rejection_reason"]
    assert_equal rejected.merge("replayed" => true), register(@host, stale)
    assert_equal 5, @host.receipt_count
  end

  # REG-09: compare the entire durable database rows, including sequence/clock.
  def test_registration_transport_failures_do_not_touch_durable_bookkeeping
    database_rows = lambda do
      db = SQLite3::Database.new(@args[:path])
      begin
        %w[auctions receipts commits outbox].to_h { |table| [table, db.execute("SELECT * FROM #{table}")] }
      ensure
        db.close
      end
    end
    before = database_rows.call
    bad = %w[operator_id effective_at state version group_id unknown].map { |key| registration.merge(key => "spoof") }
    bad << JSON.generate(registration).sub('{', '{"unit_id":"duplicate",')
    bad << JSON.generate(registration).sub("Synthetic", "\xFF".b).force_encoding(Encoding::UTF_8)
    invalid = registration
    invalid["configuration"]["closes_at"] = invalid["configuration"]["opens_at"]
    bad << invalid
    bad.each do |intent|
      assert_raises(ArgumentError) { register(@host, intent) }
      assert_equal before, database_rows.call
    end
  end

  # REG-11: standalone creation is a separate commit from guarded attachment.
  def test_registration_then_attachment_preserves_bids_and_failed_attachment
    assert_nil register["rejection_reason"]
    standalone, configs = @host.snapshot, @host.configurations
    attach = copy(@intent)
    attach["expected_schedule_revision"] = 8
    attach["expected_units"] << {"unit_id" => "unit-new", "version" => 0}
    attach["resulting_closing_sets"][0]["member_unit_ids"] << "unit-new"
    stale = attach.merge("command_id" => "stale-attach", "expected_schedule_revision" => 7)
    assert_equal "stale_revision", edit(@host, stale)["rejection_reason"]
    assert_equal standalone, @host.snapshot
    response = edit(@host, attach)
    assert_nil response["rejection_reason"]
    assert_equal 9, @host.snapshot["schedule_revision"]
    assert_equal configs, @host.configurations
    standalone["units"].each do |id, unit|
      assert_equal unit["positions"], @host.snapshot["units"][id]["positions"]
      assert_equal unit["authorization_history"], @host.snapshot["units"][id]["authorization_history"]
      assert_equal unit["version"] + 1, @host.snapshot["units"][id]["version"]
    end
    assert_equal 1, @host.snapshot["closing_sets"].size
  end

  # REG-13: independent connections share the revision boundary.
  def test_independent_registration_edit_race_has_one_revision_winner
    before, configs = @host.snapshot, @host.configurations
    results = race { |host, index| index.zero? ? register(host) : edit(host) }
    assert_equal [nil, "stale_revision"], results.map { |r| r["rejection_reason"] }.sort_by(&:to_s)
    assert_equal 8, @host.snapshot["schedule_revision"]
    assert_equal 2, @host.receipt_count
    assert_registration_journal_replays(before, configs)
  end

  def test_independent_registration_existing_bid_race_preserves_both_commits
    before, configs = @host.snapshot, @host.configurations
    results = race do |host, index|
      index.zero? ? register(host) : host.bid(unit_id: "unit-a",
        command: {"type" => "place_bid", "command_id" => "registration-racing-bid", "maximum_minor_units" => 5000}, principal_id: "bidder-new")
    end
    results.each { |response| assert_nil response["rejection_reason"] }
    assert_equal 8, @host.snapshot["schedule_revision"]
    assert_equal 2, @host.snapshot["units"]["unit-a"]["version"]
    assert_equal "bidder-new", @host.snapshot["units"]["unit-a"]["leader_id"]
    assert_equal 0, @host.snapshot["units"]["unit-new"]["version"]
    assert_equal 2, @host.receipt_count
    assert_registration_journal_replays(before, configs)
  end

  # REG-14: unknown-before-create may reject; after-create must preserve its bid.
  def test_independent_registration_new_unit_bid_race_is_serializable
    before, configs = @host.snapshot, @host.configurations
    command = {"type" => "place_bid", "command_id" => "new-racing-bid", "maximum_minor_units" => 5000}
    results = race do |host, index|
      index.zero? ? register(host) : host.bid(unit_id: "unit-new", command: command, principal_id: "bidder-new")
    end
    assert_nil results[0]["rejection_reason"]
    assert_includes [nil, "invalid_request"], results[1]["rejection_reason"]
    assert_equal results[1]["rejection_reason"] ? 0 : 1, @host.snapshot["units"]["unit-new"]["version"]
    assert_equal 2, @host.receipt_count
    assert_registration_journal_replays(before, configs)
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal results[1].merge("replayed" => true), reopened.bid(unit_id: "unit-new", command: command, principal_id: "bidder-new")
    assert_nil reopened.bid(unit_id: "unit-new", command: command.merge("command_id" => "new-after-reopen"), principal_id: "bidder-other")["rejection_reason"]
    assert_equal results[1]["rejection_reason"] ? 1 : 2, reopened.snapshot["units"]["unit-new"]["version"]
  end

  def test_registration_future_opening_rejects_early_bid_without_erasing_inventory
    intent = registration
    intent["configuration"]["opens_at"] = "2031-04-17T12:10:00Z"
    assert_nil register(@host, intent)["rejection_reason"]
    before, configs = @host.snapshot, @host.configurations
    response = @host.bid(unit_id: "unit-new", command: {"type" => "place_bid",
      "command_id" => "early-bid", "maximum_minor_units" => 5000}, principal_id: "bidder-new")
    assert_equal "bidding_not_open", response["rejection_reason"]
    assert_equal before, @host.snapshot
    assert_equal configs, @host.configurations
  end

  def test_registration_cannot_reuse_a_closed_unit_identity
    @at = "2031-04-17T15:00:00Z"
    assert_nil @host.close(unit_id: "unit-c", command_id: "close-existing", principal_id: "operator-demo", permissions: ["close"])["rejection_reason"]
    before, configs = @host.snapshot, @host.configurations
    intent = registration("reuse-terminal", "unit-c").merge("expected_schedule_revision" => before["schedule_revision"])
    intent["configuration"]["closes_at"] = "2031-04-17T16:00:00Z"
    response = register(@host, intent)
    assert_equal "unit_id_conflict", response["rejection_reason"]
    assert_equal response.merge("replayed" => true), register(@host, intent)
    assert_equal before, @host.snapshot
    assert_equal configs, @host.configurations
  end

  def test_independent_registration_close_race_preserves_closed_existing_units
    @at = "2031-04-17T15:00:00Z"
    before, configs = @host.snapshot, @host.configurations
    intent = registration
    intent["configuration"]["closes_at"] = "2031-04-17T16:00:00Z"
    results = race do |host, index|
      index.zero? ? register(host, intent) : host.close(group_id: "group-left", command_id: "registration-racing-close", principal_id: "operator-demo", permissions: ["close"])
    end
    assert_nil results[1]["rejection_reason"]
    assert_includes [nil, "stale_revision"], results[0]["rejection_reason"]
    %w[unit-a unit-b].each { |id| assert_equal "closed", @host.snapshot["units"][id]["status"] }
    assert_equal 2, @host.receipt_count
    assert_registration_journal_replays(before, configs)
  end

  def assert_registration_journal_replays(before, configs)
    projection = {"snapshot" => before, "configurations" => configs}
    @host.deliver_pending do |batch|
      records = batch.map { |item| item.fetch("record") }
      projection = RBBB::LiveScheduling::Projector.apply_commit(snapshot: projection["snapshot"],
        configurations: projection["configurations"], records: records, policy: @args[:policy], auction_id: @args[:auction_id])
    end
    assert_equal @host.snapshot, projection["snapshot"]
    assert_equal @host.configurations, projection["configurations"]
  end

  def test_operator_void_is_durable_authorized_and_does_not_extend_the_group
    bid = {"type" => "place_bid", "command_id" => "void-target", "bid_id" => "bid-target", "maximum_minor_units" => 5000}
    assert_nil @host.bid(unit_id: "unit-c", command: bid, principal_id: "bidder-new")["rejection_reason"]
    before = @host.snapshot
    command = {"type" => "void_bid", "command_id" => "void-command", "bid_id" => "bid-target",
      "reason" => "Synthetic operator correction", "notification_policy" => "affected"}
    response = @host.void_bid(unit_id: "unit-c", command: command, principal_id: "operator-demo", permissions: ["void"])
    assert_nil response["rejection_reason"]
    assert_equal before["closing_sets"], @host.snapshot["closing_sets"]
    assert_equal before["schedule_revision"], @host.snapshot["schedule_revision"]
    assert_equal ["bid-target"], @host.snapshot["units"]["unit-c"]["voided_bid_ids"]
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal response.merge("replayed" => true), reopened.void_bid(unit_id: "unit-c", command: command, principal_id: "operator-demo", permissions: ["void"])
    denied = reopened.void_bid(unit_id: "unit-c", command: command, principal_id: "operator-demo", permissions: [])
    assert_equal "not_authorized", denied["rejection_reason"]
    assert_empty denied["records"]
    assert_equal "command_id_reused", reopened.void_bid(unit_id: "unit-c", command: command.merge("reason" => "Changed"), principal_id: "operator-demo", permissions: ["void"])["rejection_reason"]
    assert_raises(ArgumentError) { reopened.void_bid(unit_id: "unit-c", command: command.merge("operator_id" => "spoof"), principal_id: "operator-demo", permissions: ["void"]) }
  end

  def test_void_commit_failure_rolls_back_state_receipt_history_and_outbox
    @host.bid(unit_id: "unit-c", command: {"type" => "place_bid", "command_id" => "rollback-target", "bid_id" => "rollback-bid", "maximum_minor_units" => 5000}, principal_id: "bidder-new")
    before = @host.snapshot
    history = @host.records
    count = @host.receipt_count
    failing = Class.new(RBBBExamples::LiveSchedulingHost) do
      private
      def before_commit(_db) = raise("synthetic commit failure")
    end.new(**@args)
    command = {"type" => "void_bid", "command_id" => "rollback-void", "bid_id" => "rollback-bid", "reason" => "Synthetic correction", "notification_policy" => "affected"}
    assert_raises(RuntimeError) { failing.void_bid(unit_id: "unit-c", command: command, principal_id: "operator-demo", permissions: ["void"]) }
    assert_equal before, @host.snapshot
    assert_equal history, @host.records
    assert_equal count, @host.receipt_count
    batches = []
    @host.deliver_pending { |batch| batches << batch }
    assert_equal history, batches.flat_map { |batch| batch.map { |record| record["record"] } }
    assert_nil @host.void_bid(unit_id: "unit-c", command: command, principal_id: "operator-demo", permissions: ["void"])["rejection_reason"]
  end

  def test_void_process_kill_before_and_after_commit_preserves_exact_replay_and_delivery
    bid = {"type" => "place_bid", "command_id" => "crash-void-target", "bid_id" => "crash-void-bid", "maximum_minor_units" => 5000}
    assert_nil @host.bid(unit_id: "unit-c", command: bid, principal_id: "bidder-new")["rejection_reason"]
    # Acknowledge the prerequisite bid so delivery assertions isolate the void.
    assert_equal 1, @host.deliver_pending { |_batch| }
    before = @host.snapshot
    history = @host.records
    count = @host.receipt_count
    command = {"type" => "void_bid", "command_id" => "crash-void-command", "bid_id" => "crash-void-bid",
      "reason" => "Synthetic correction", "notification_policy" => "affected"}
    execute = ->(host) { host.void_bid(unit_id: "unit-c", command: command, principal_id: "operator-demo", permissions: ["void"]) }

    kill_at(:before_commit) { |host| execute.call(host) }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal before, reopened.snapshot
    assert_equal history, reopened.records
    assert_equal count, reopened.receipt_count
    assert_equal 0, reopened.deliver_pending { flunk "uncommitted void delivery" }

    kill_at(:after_commit) { |host| execute.call(host) }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal count + 1, reopened.receipt_count
    assert_equal ["crash-void-bid"], reopened.snapshot["units"]["unit-c"]["voided_bid_ids"]
    assert_equal before["closing_sets"], reopened.snapshot["closing_sets"]
    assert_equal before["schedule_revision"], reopened.snapshot["schedule_revision"]
    committed = reopened.snapshot
    void_records = reopened.records.drop(history.size)
    refute_empty void_records
    reopened.seal!
    restored = RBBBExamples::LiveSchedulingHost.new(**@args.merge(clock: -> { raise "retained void must not allocate time" }))
    response = execute.call(restored)
    assert response["replayed"]
    assert_nil response["rejection_reason"]
    assert_equal void_records, response["records"]
    assert_equal committed, restored.snapshot
    assert_equal count + 1, restored.receipt_count
    assert_equal 1, restored.deliver_pending { |batch| assert_equal void_records, batch.map { |entry| entry["record"] } }
    assert_equal 0, restored.deliver_pending { flunk "duplicate void delivery" }
  end

  def reserve_command(id = "reserve-command", amount = 100)
    {"type" => "change_reserve", "command_id" => id, "reserve_minor_units" => amount,
      "reason" => "Synthetic reserve correction", "notification_policy" => "affected"}
  end

  def reserve(host = @host, command = reserve_command, principal = "operator-demo", permissions = ["reserve"])
    host.change_reserve(unit_id: "unit-c", command: command, principal_id: principal, permissions: permissions)
  end

  def test_reserve_change_is_durable_authorized_and_preserves_scheduling
    before = @host.snapshot
    response = reserve
    assert_nil response["rejection_reason"]
    after = @host.snapshot
    assert_equal 100, after["units"]["unit-c"]["reserve_minor_units"]
    assert_equal before["units"]["unit-c"]["version"] + 1, after["units"]["unit-c"]["version"]
    normalize_sets = ->(sets) { sets.map { |set| set.merge("closes_at" => RBBB::Timestamp.dump(RBBB::Timestamp.parse(set["closes_at"]))) } }
    assert_equal normalize_sets.call(before["closing_sets"]), normalize_sets.call(after["closing_sets"])
    assert_equal before["schedule_revision"], after["schedule_revision"]
    @host.seal!
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args.merge(clock: -> { raise "replay must not allocate time" }))
    assert_equal response.merge("replayed" => true), reserve(reopened)
    [reserve(reopened, reserve_command, "other-operator"), reserve(reopened, reserve_command, "operator-demo", [])].each do |denied|
      assert_equal "not_authorized", denied["rejection_reason"]
      assert_empty denied["records"]
    end
    assert_equal "command_id_reused", reserve(reopened, reserve_command("reserve-command", 50))["rejection_reason"]
    %w[operator_id effective_at].each do |field|
      assert_raises(ArgumentError) { reserve(@host, reserve_command.merge(field => "spoof")) }
    end
  end

  def test_reserve_commit_failure_rolls_back_and_retry_commits_once
    before, history, count = @host.snapshot, @host.records, @host.receipt_count
    failing = Class.new(RBBBExamples::LiveSchedulingHost) do
      private
      def before_commit(_db) = raise("synthetic commit failure")
    end.new(**@args)
    assert_raises(RuntimeError) { reserve(failing) }
    assert_equal before, @host.snapshot
    assert_equal history, @host.records
    assert_equal count, @host.receipt_count
    assert_equal 0, @host.deliver_pending { flunk "rolled-back reserve published" }
    response = reserve
    assert_nil response["rejection_reason"]
    assert_equal count + 1, @host.receipt_count
    assert_equal response.merge("replayed" => true), reserve
    delivered = []
    assert_equal 1, @host.deliver_pending { |batch| delivered.concat(batch.map { |item| item["record"] }) }
    assert_equal response["records"], delivered
  end

  def test_reserve_increase_after_bidding_retains_rejection_without_domain_effects
    assert_nil @host.bid(unit_id: "unit-c", command: {"type" => "place_bid", "command_id" => "reserve-bid", "bid_id" => "reserve-bid-id", "maximum_minor_units" => 5000}, principal_id: "bidder-new")["rejection_reason"]
    before, history = @host.snapshot, @host.records
    response = reserve(@host, reserve_command("increase", 6000))
    assert_equal "reserve_may_not_increase_after_first_bid", response["rejection_reason"]
    assert_equal before, @host.snapshot
    assert_equal history, @host.records
    assert_equal response.merge("replayed" => true), reserve(@host, reserve_command("increase", 6000))
  end

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

  def test_reserve_process_kill_before_and_after_commit
    before = @host.snapshot
    kill_at(:before_commit) { |host| reserve(host) }
    assert_equal before, @host.snapshot
    assert_equal 0, @host.receipt_count
    assert_empty @host.records
    assert_equal 0, @host.deliver_pending { flunk "uncommitted reserve delivery" }
    kill_at(:after_commit) { |host| reserve(host) }
    reopened = RBBBExamples::LiveSchedulingHost.new(**@args)
    assert_equal 100, reopened.snapshot["units"]["unit-c"]["reserve_minor_units"]
    assert_equal 1, reopened.receipt_count
    response = reserve(reopened)
    assert response["replayed"]
    assert_nil response["rejection_reason"]
    assert_equal reopened.records, response["records"]
    assert_equal 1, reopened.deliver_pending { |batch| assert_equal response["records"], batch.map { |item| item["record"] } }
  end

  def test_independent_process_reserve_bid_race_respects_durable_order
    results = race do |host, index|
      if index.zero?
        reserve(host, reserve_command("race-reserve", 6000))
      else
        host.bid(unit_id: "unit-c", command: {"type" => "place_bid", "command_id" => "race-reserve-bid", "bid_id" => "race-reserve-bid-id", "maximum_minor_units" => 5000}, principal_id: "bidder-new")
      end
    end
    assert_nil results[1]["rejection_reason"]
    assert_includes [nil, "reserve_may_not_increase_after_first_bid"], results[0]["rejection_reason"]
    unit = @host.snapshot["units"]["unit-c"]
    if results[0]["rejection_reason"]
      assert_nil unit["reserve_minor_units"]
      assert_equal 1, unit["version"]
    else
      assert_equal 6000, unit["reserve_minor_units"]
      assert_equal 2, unit["version"]
    end
    assert_equal 2, @host.receipt_count
    assert_equal 7, @host.snapshot["schedule_revision"]
    assert_equal results[0].merge("replayed" => true), reserve(@host, reserve_command("race-reserve", 6000))
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
