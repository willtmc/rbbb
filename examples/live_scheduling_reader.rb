# frozen_string_literal: true

require "json"
require "digest"
require_relative "live_scheduling_host"

module RBBBExamples
  # Trusted embedding adapter, NOT an authentication implementation or endpoint.
  # Callbacks must consult current server-owned identity/policy, never request
  # roles. Public checkpoints are refetch-only views, not replayable engine state.
  class LiveSchedulingReader
    class NotAuthorized < StandardError; end

    def initialize(host:, authenticate:, authorize:, visible:)
      @host, @authenticate, @authorize, @visible = host, authenticate, authorize, visible
    end

    def checkpoint(credential:, visibility:)
      raise ArgumentError, "unsupported visibility" unless %w[public privileged].include?(visibility)
      principal = @authenticate.call(credential)
      raise NotAuthorized, "not authorized" unless principal.is_a?(String) && !principal.empty?
      @host.read_checkpoint do |checkpoint|
        scope = {principal_id: principal, tenant_id: checkpoint.fetch("tenant_id"),
          auction_id: checkpoint.fetch("auction_id"), visibility: visibility}
        raise NotAuthorized, "not authorized" unless @authorize.call(**scope) == true
        snapshot = checkpoint.fetch("snapshot")
        ids = snapshot.fetch("units").keys.sort.select do |id|
          @visible.call(**scope, unit_id: id) == true
        end
        if visibility == "privileged" && ids.size != snapshot.fetch("units").size
          raise NotAuthorized, "not authorized"
        end
        projected = if visibility == "privileged"
          snapshot
        else
          {"schedule_revision" => snapshot.fetch("schedule_revision"),
            "units" => ids.to_h { |id| [id, RBBB::State.from_h(snapshot.fetch("units").fetch(id)).public_view] }}
        end
        payload = {"tenant_id" => checkpoint.fetch("tenant_id"),
          "auction_id" => checkpoint.fetch("auction_id"), "visibility" => visibility,
          "decision_sequence" => checkpoint.fetch("decision_sequence"), "snapshot" => projected}
        # Hash ONLY this authorized payload, never privileged state for a public
        # response. Reauthorize every refetch; no shared cross-principal cache.
        {"payload" => payload, "sha256" => Digest::SHA256.hexdigest(JSON.generate(payload))}
      end
    end
  end
end
