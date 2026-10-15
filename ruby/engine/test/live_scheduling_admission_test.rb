# frozen_string_literal: true

require_relative "test_helper"
require_relative "../../../examples/live_scheduling_admission"

class LiveSchedulingAdmissionTest < Minitest::Test
  class RecordingHost
    attr_reader :calls
    def initialize = @calls = []
    def tenant_id = "tenant-demo"
    def auction_id = "auction-demo"
    RBBBExamples::LiveSchedulingAdmission::OPERATIONS.each_key do |operation|
      define_method(operation) { |**args| @calls << [operation, args]; {"accepted" => true} }
    end
  end

  def setup
    @host = RecordingHost.new
    @allowed = true
    @grants = %w[schedule shorten register bid void reserve close]
    @scopes = []
    @adapter = RBBBExamples::LiveSchedulingAdmission.new(host: @host,
      authenticate: ->(credential) { credential == "valid" ? "principal-demo" : nil },
      authorize: ->(**scope) { @scopes << scope; @allowed },
      permissions: ->(**_scope) { @grants })
  end

  def test_all_mutations_receive_only_server_owned_authority
    RBBBExamples::LiveSchedulingAdmission::OPERATIONS.each do |operation, action|
      assert_equal({"accepted" => true}, @adapter.public_send(operation, credential: "valid", command_id: "synthetic"))
      actual_operation, args = @host.calls.last
      assert_equal operation, actual_operation
      assert_equal "principal-demo", args[:principal_id]
      assert_equal "tenant-demo", @scopes.last[:tenant_id]
      assert_equal "auction-demo", @scopes.last[:auction_id]
      assert_equal action, @scopes.last[:action]
      operation == :bid ? refute(args.key?(:permissions)) : assert_equal(@grants, args[:permissions])
      refute args.key?(:credential)
    end
  end

  def test_authentication_and_strict_authorization_fail_before_host_access
    assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { @adapter.bid(credential: "invalid") }
    [false, nil, "true", 1].each do |grant|
      @allowed = grant
      assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { @adapter.bid(credential: "valid") }
    end
    assert_empty @host.calls
  end

  def test_permissions_are_reloaded_for_every_submission_including_retry
    @adapter.close(credential: "valid", command_id: "same-command")
    @grants = []
    assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { @adapter.close(credential: "valid", command_id: "same-command") }
    assert_equal 1, @host.calls.size
    @grants = "close"
    assert_raises(RBBBExamples::LiveSchedulingAdmission::NotAuthorized) { @adapter.close(credential: "valid") }
  end

  def test_client_authority_is_never_forwarded
    [:principal_id, :permissions].each do |key|
      assert_raises(ArgumentError) { @adapter.close(credential: "valid", **{key => "spoofed"}) }
    end
    assert_empty @host.calls
  end
end
