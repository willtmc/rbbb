# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require_relative "../../../examples/live_scheduling_reader"

class LiveSchedulingReaderTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    vector = JSON.parse(File.readlines(File.expand_path("../../../rfcs/proposals/flexible-live-scheduling/behavior-vectors.jsonl", __dir__)).first)
    @host = RBBBExamples::LiveSchedulingHost.new(path: File.join(@dir, "reader.sqlite3"),
      tenant_id: "tenant-demo", auction_id: "auction-demo",
      configurations: vector["unit_setup"].transform_values { |setup| setup["configuration"] },
      snapshot: vector["initial_state"], policy: vector["scheduling_policy"], clock: -> { "2031-04-17T12:00:00Z" })
    @intent = vector["steps"].first["action"]["submitted_intent"]
    @allowed = true
    @visible = true
    @reader = RBBBExamples::LiveSchedulingReader.new(host: @host,
      authenticate: ->(token) { token == "synthetic-token" ? "reader-demo" : nil },
      authorize: ->(**scope) { @scope = scope; @allowed },
      visible: ->(**scope) { @visible && scope[:unit_id] != @hidden })
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def checkpoint(visibility = "public")
    @reader.checkpoint(credential: "synthetic-token", visibility: visibility)
  end

  def test_denies_anonymous_revoked_non_boolean_and_unknown_visibility
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { @reader.checkpoint(credential: nil, visibility: "public") }
    checkpoint
    @allowed = false
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { checkpoint }
    @allowed = "true"
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { checkpoint }
    assert_raises(ArgumentError) { checkpoint("admin") }
    assert_equal 0, @host.receipt_count
    assert_empty @host.records
  end

  def test_public_digest_is_of_only_authorized_projection_and_catalog_is_checked_each_time
    @hidden = @host.snapshot.fetch("units").keys.first
    result = checkpoint
    payload = result.fetch("payload")
    refute payload.fetch("snapshot").fetch("units").key?(@hidden)
    expected = @host.snapshot.fetch("units").reject { |id, _| id == @hidden }.transform_values { |unit| RBBB::State.from_h(unit).public_view }
    assert_equal expected, payload.fetch("snapshot").fetch("units")
    refute payload.fetch("snapshot").key?("closing_sets")
    assert_equal Digest::SHA256.hexdigest(JSON.generate(payload)), result.fetch("sha256")
    assert_equal "tenant-demo", @scope[:tenant_id]
    assert_equal "auction-demo", @scope[:auction_id]
    assert_equal "reader-demo", @scope[:principal_id]
    @visible = false
    assert_empty checkpoint.fetch("payload").fetch("snapshot").fetch("units")
  end

  def test_privileged_snapshot_is_detached_all_or_nothing_and_visibility_scoped
    public_result = checkpoint
    private_result = checkpoint("privileged")
    assert_equal @host.snapshot, private_result.fetch("payload").fetch("snapshot")
    refute_equal public_result.fetch("sha256"), private_result.fetch("sha256")
    private_result.fetch("payload").fetch("snapshot")["units"].clear
    refute_empty @host.snapshot.fetch("units")
    @hidden = @host.snapshot.fetch("units").keys.first
    assert_raises(RBBBExamples::LiveSchedulingReader::NotAuthorized) { checkpoint("privileged") }
  end

  def test_checkpoint_sequence_and_revision_follow_whole_commit_without_read_mutation
    before = checkpoint
    response = @host.edit(intent: @intent, principal_id: "operator-demo", permissions: ["schedule", "shorten"])
    assert_nil response["rejection_reason"]
    after = checkpoint
    assert_equal before["payload"]["decision_sequence"] + 1, after["payload"]["decision_sequence"]
    assert_equal @host.snapshot["schedule_revision"], after["payload"]["snapshot"]["schedule_revision"]
    assert_equal after, checkpoint
    assert_equal 1, @host.receipt_count
  end
end
