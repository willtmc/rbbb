# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/live_scheduling_admission"

class LiveSchedulingAdmissionIntegrationTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    vector = JSON.parse(File.readlines(File.expand_path("../../../rfcs/proposals/flexible-live-scheduling/behavior-vectors.jsonl", __dir__)).first)
    @path = File.join(@dir, "auction.sqlite3")
    @at = "2031-04-17T12:00:00Z"
    @host = RBBBExamples::LiveSchedulingHost.new(path: @path, tenant_id: "tenant-demo", auction_id: "auction-demo",
      configurations: vector["unit_setup"].transform_values { |setup| setup["configuration"] },
      snapshot: vector["initial_state"], policy: vector["scheduling_policy"], clock: -> { @at })
    @intent = vector["steps"].first["action"]["submitted_intent"]
    @allowed = true
    @principal = "operator-demo"
    @grants = %w[schedule shorten register bid void reserve close]
    @adapter = RBBBExamples::LiveSchedulingAdmission.new(host: @host,
      authenticate: ->(credential) { credential == "valid" ? @principal : nil },
      authorize: ->(**_scope) { @allowed }, permissions: ->(**_scope) { @grants })
    @operations = {
      edit: {intent: @intent},
      register_unit: {intent: {"type" => "register_unit", "command_id" => "register-demo", "auction_id" => "auction-demo",
        "unit_id" => "unit-new", "expected_schedule_revision" => 7,
        "configuration" => vector["unit_setup"]["unit-c"]["configuration"].merge("reserve_minor_units" => nil), "reason" => "Synthetic registration"}},
      bid: {unit_id: "unit-c", command: {"type" => "place_bid", "command_id" => "bid-demo", "bid_id" => "bid-demo", "maximum_minor_units" => 5000}},
      void_bid: {unit_id: "unit-c", command: {"type" => "void_bid", "command_id" => "void-demo", "bid_id" => "bid-demo", "reason" => "Synthetic correction", "notification_policy" => "affected"}},
      change_reserve: {unit_id: "unit-c", command: {"type" => "change_reserve", "command_id" => "reserve-demo", "reserve_minor_units" => 100,
        "reason" => "Synthetic correction", "notification_policy" => "affected"}},
      close: {unit_id: "unit-c", command_id: "close-demo"}
    }
  end

  def teardown = FileUtils.remove_entry(@dir)

  def rows
    db = SQLite3::Database.new(@path)
    %w[auctions receipts commits outbox].to_h { |table| [table, db.execute("SELECT * FROM #{table} ORDER BY rowid")] }
  ensure
    db&.close
  end

  def submit(operation, **extra)
    @adapter.public_send(operation, credential: "valid", **@operations.fetch(operation), **extra)
  end

  def test_all_entrypoints_deny_before_any_durable_bookkeeping
    @operations.each_key do |operation|
      before = rows
      @allowed = false
      assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { submit(operation) }
      @allowed = true
      @grants = []
      assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { submit(operation) }
      @grants = RBBBExamples::LiveSchedulingAdmission::OPERATIONS.values
      [:principal_id, :permissions].each do |field|
        assert_raises(ArgumentError) { submit(operation, **{field => "spoofed"}) }
      end
      assert_equal before, rows, operation.to_s
    end
  end

  def test_edit_receipt_boundary = assert_receipt_boundary(:edit)

  def test_registration_receipt_boundary = assert_receipt_boundary(:register_unit)
  def test_bid_receipt_boundary = assert_receipt_boundary(:bid)
  def test_reserve_receipt_boundary = assert_receipt_boundary(:change_reserve)

  def test_void_receipt_boundary
    assert_nil submit(:bid)["rejection_reason"]
    assert_receipt_boundary(:void_bid)
  end

  def test_close_receipt_boundary
    @at = "2031-04-17T16:00:00Z"
    assert_receipt_boundary(:close)
  end

  def assert_receipt_boundary(operation)
    response = submit(operation)
    assert_nil response["rejection_reason"], operation.to_s
    refute_empty response["records"]
    before = rows
    assert_equal response.merge("replayed" => true), submit(operation)
    assert_equal before, rows
    @grants = []
    assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { submit(operation) }
    assert_equal before, rows
    @grants = %w[schedule shorten register bid void reserve close]
    @allowed = false
    assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { submit(operation) }
    assert_equal before, rows
    @allowed = true
    @principal = "different-principal"
    denied = submit(operation)
    assert_equal "not_authorized", denied["rejection_reason"]
    assert_empty denied["records"]
    assert_equal before, rows
  end

  def test_schedule_grant_does_not_imply_shorten
    @grants = ["schedule"]
    @intent["allow_shortening"] = true
    @intent["resulting_closing_sets"].first["closes_at"] = "2031-04-17T14:00:00Z"
    before = @host.snapshot
    response = submit(:edit)
    assert_equal "shortening_not_allowed", response["rejection_reason"]
    assert_equal before, @host.snapshot
    assert_empty @host.records
    assert_equal 1, @host.receipt_count # Domain denial is retained, unlike adapter denial.
    @grants << "shorten"
    assert_equal response.merge("replayed" => true), submit(:edit)
    @intent["command_id"] = "authorized-shortening"
    assert_nil submit(:edit)["rejection_reason"]
    assert_equal "2031-04-17T14:00:00Z", @host.snapshot["closing_sets"].first["closes_at"]
  end
end
