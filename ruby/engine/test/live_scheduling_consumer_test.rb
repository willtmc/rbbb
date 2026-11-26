# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/live_scheduling_consumer"

class LiveSchedulingConsumerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "consumer.sqlite3")
    vector = JSON.parse(File.readlines(File.expand_path("../../../rfcs/proposals/flexible-live-scheduling/behavior-vectors.jsonl", __dir__)).first)
    @host = RBBBExamples::LiveSchedulingHost.new(path: File.join(@dir, "host.sqlite3"),
      tenant_id: "tenant-demo", auction_id: "auction-demo",
      configurations: vector["unit_setup"].transform_values { |setup| setup["configuration"] },
      snapshot: vector["initial_state"], policy: vector["scheduling_policy"], clock: -> { "2031-04-17T12:00:00Z" })
    @intent = vector["steps"].first["action"]["submitted_intent"]
    @allowed = true
    @context = "synthetic-reader-policy-1"
    @reader = RBBBExamples::LiveSchedulingReader.new(host: @host,
      authenticate: ->(token) { token == "token" ? "reader-demo" : nil },
      authorize: ->(**_scope) { @allowed },
      visible: ->(**scope) { scope[:unit_id] != @hidden },
      authorization_context: ->(**_scope) { @context })
    @fetch = ->(**args) { @reader.checkpoint(**args) }
    @args = {path: @path, tenant_id: "tenant-demo", auction_id: "auction-demo", visibility: "public", fetch: @fetch}
    @consumer = RBBBExamples::LiveSchedulingConsumer.new(**@args)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def stored
    db = SQLite3::Database.new(@path)
    raw = db.get_first_value("SELECT document FROM installation")
    raw && JSON.parse(raw)
  ensure
    db&.close
  end

  def read = @consumer.read(credential: "token")

  def test_atomic_detached_install_duplicate_and_reopen_without_authority_mutation
    before = @host.snapshot
    result = read
    assert_equal result, stored
    result["payload"]["snapshot"]["units"].clear
    refute_empty stored["payload"]["snapshot"]["units"]
    assert_equal stored, read
    reopened = RBBBExamples::LiveSchedulingConsumer.new(**@args)
    assert_equal stored, reopened.read(credential: "token")
    assert_equal before, @host.snapshot
    assert_equal 0, @host.receipt_count
    assert_empty @host.records
    assert_equal 0o600, File.stat(@path).mode & 0o777
  end

  def test_denial_revocation_and_unknown_context_invalidate_persistent_installation
    read
    @allowed = "true"
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { read }
    assert_nil stored
    @allowed = true
    read
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { @consumer.read(credential: "wrong") }
    assert_nil stored
    read
    @context = nil
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { read }
    assert_nil stored
  end

  def test_catalog_policy_change_replaces_view_with_only_authorized_digest
    old = read
    @hidden = @host.snapshot["units"].keys.first
    @context = "synthetic-reader-policy-2"
    current = read
    refute current["payload"]["snapshot"]["units"].key?(@hidden)
    refute_equal old["sha256"], current["sha256"]
    assert_equal current, stored
    assert_equal Digest::SHA256.hexdigest(JSON.generate(current["payload"])), current["sha256"]
    refute current["payload"]["snapshot"].key?("closing_sets")
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) do
      @reader.checkpoint(credential: "token", visibility: "privileged")
    end # privileged whole-snapshot disclosure refuses partial catalog
  end

  def test_scope_digest_and_conflicting_identity_fail_closed
    original = read
    mutated = JSON.parse(JSON.generate(original))
    mutated["payload"]["snapshot"]["units"].clear
    mutated["sha256"] = Digest::SHA256.hexdigest(JSON.generate(mutated["payload"]))
    adapter = RBBBExamples::LiveSchedulingConsumer.new(**@args.merge(fetch: ->(**_args) { mutated }))
    assert_raises(RBBBExamples::LiveSchedulingConsumer::InvalidCheckpoint) { adapter.read(credential: "token") }
    assert_equal original, stored
    %w[tenant_id auction_id visibility].each do |field|
      changed = JSON.parse(JSON.generate(original))
      changed["payload"][field] = "wrong"
      changed["sha256"] = Digest::SHA256.hexdigest(JSON.generate(changed["payload"]))
      adapter = RBBBExamples::LiveSchedulingConsumer.new(**@args.merge(fetch: ->(**_args) { changed }))
      assert_raises(RBBBExamples::LiveSchedulingConsumer::InvalidCheckpoint) { adapter.read(credential: "token") }
    end
    broken = original.merge("sha256" => "incorrect")
    adapter = RBBBExamples::LiveSchedulingConsumer.new(**@args.merge(fetch: ->(**_args) { broken }))
    assert_raises(RBBBExamples::LiveSchedulingConsumer::InvalidCheckpoint) { adapter.read(credential: "token") }
    assert_equal original, stored
  end

  def test_public_and_privileged_stores_are_isolated_and_no_offline_fallback_is_served
    public_result = read
    private_args = @args.merge(path: File.join(@dir, "private.sqlite3"), visibility: "privileged")
    private_consumer = RBBBExamples::LiveSchedulingConsumer.new(**private_args)
    private_result = private_consumer.read(credential: "token")
    assert_equal @host.snapshot, private_result["payload"]["snapshot"]
    refute_equal public_result["sha256"], private_result["sha256"]
    assert_equal %w[payload sha256], public_result.keys.sort
    # Even a valid digest from the privileged reader cannot cross the public scope.
    wrong_reader = RBBBExamples::LiveSchedulingConsumer.new(**@args.merge(fetch: ->(**_args) { private_result }))
    assert_raises(RBBBExamples::LiveSchedulingConsumer::InvalidCheckpoint) { wrong_reader.read(credential: "token") }
    unavailable = RBBBExamples::LiveSchedulingConsumer.new(**@args.merge(fetch: ->(**_args) { raise IOError, "synthetic unavailable" }))
    assert_raises(IOError) { unavailable.read(credential: "token") }
    assert_equal public_result, stored # retained for recovery, never returned on failure
  end

  def test_rejected_decision_gap_is_snapshot_checkpoint_not_event_cursor
    before = read
    rejected = @intent.merge("expected_schedule_revision" => 0)
    assert @host.edit(intent: rejected, principal_id: "operator-demo", permissions: ["schedule"])["rejection_reason"]
    after = read
    assert_equal before["payload"]["snapshot"], after["payload"]["snapshot"]
    assert_equal before["payload"]["decision_sequence"] + 1, after["payload"]["decision_sequence"]
    assert_equal after, stored
  end

  def test_real_process_kill_preserves_old_or_complete_new_installation
    skip "fork unavailable" unless Process.respond_to?(:fork)
    old = read
    @host.edit(intent: @intent, principal_id: "operator-demo", permissions: %w[schedule shorten])
    expected = @reader.checkpoint(credential: "token", visibility: "public")
    [:before_install_commit, :after_install_commit].each do |hook|
      klass = Class.new(RBBBExamples::LiveSchedulingConsumer) do
        define_method(hook) { Process.kill("KILL", Process.pid) }
      end
      pid = fork { klass.new(**@args).read(credential: "token"); exit! 9 }
      Process.wait(pid)
      assert $?.signaled?
      assert_equal Signal.list.fetch("KILL"), $?.termsig
      assert_equal hook == :before_install_commit ? old : expected, stored
    end
    assert_equal expected, read
  end
end
