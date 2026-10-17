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
