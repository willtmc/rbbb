# frozen_string_literal: true

require_relative "live_scheduling_host"

module RBBBExamples
  # Trusted embedding boundary, not an identity provider or HTTP endpoint.
  # Authorization callbacks must consult current server-owned policy.
  class LiveSchedulingAdmission
    class NotAuthorized < StandardError; end

    OPERATIONS = {edit: "schedule", register_unit: "register", bid: "bid",
      void_bid: "void", change_reserve: "reserve", close: "close"}.freeze

    def initialize(host:, authenticate:, authorize:, permissions:)
      @host, @authenticate, @authorize, @permissions = host, authenticate, authorize, permissions
    end

    # Bidder-facing response: omit the host's privileged journal and other maxima.
    # Authentication, identity binding and retry authorization run through bid.
    def bidder_result(credential:, unit_id:, command:)
      response = bid(credential: credential, unit_id: unit_id, command: command)
      event = response.fetch("records").filter_map { |record| record["event"] }.find do |record|
        record["command_id"] == command["command_id"] && record.key?("bidder_notice")
      end
      {"status" => response["rejection_reason"] ? "rejected" : "accepted",
       "reason" => response["rejection_reason"], "bidder_notice" => event && event["bidder_notice"],
       "replayed" => response.fetch("replayed")}
    end

    OPERATIONS.each do |operation, action|
      define_method(operation) do |credential:, **arguments|
        # Never allow client-supplied authority, even when it matches the user.
        raise ArgumentError, "server-assigned authority" unless (arguments.keys & [:principal_id, :permissions]).empty?
        principal = @authenticate.call(credential)
        raise NotAuthorized, "not authorized" unless principal.is_a?(String) && !principal.empty?
        scope = {principal_id: principal, tenant_id: @host.tenant_id,
          auction_id: @host.auction_id, action: action}
        raise NotAuthorized, "not authorized" unless @authorize.call(**scope) == true
        grants = @permissions.call(**scope)
        raise NotAuthorized, "not authorized" unless grants.is_a?(Array) && grants.all? { |grant| grant.is_a?(String) }
        raise NotAuthorized, "not authorized" unless grants.include?(action)
        trusted = {principal_id: principal}
        trusted[:permissions] = grants.dup unless operation == :bid
        @host.public_send(operation, **arguments, **trusted)
      end
    end
  end
end
