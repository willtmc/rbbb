# frozen_string_literal: true

require "json"
require "digest"
require_relative "live_scheduling/intent"
require_relative "live_scheduling/coordinator"
require_relative "live_scheduling/projector"

module RBBB
  # Optional RFC 0004 implementation primitives. This is not a certified host or
  # an advertised capability; persistence/admission/receipt gates belong to hosts.
  module LiveScheduling
    CAPABILITY = "flexible_live_scheduling_draft_1"
    PROFILE = {"id" => "reference_scheduling_4096_v1", "affected_units" => 4096,
      "closing_sets" => 4096, "retired_groups" => 4096, "request_bytes" => 4_194_304,
      "batch_bytes" => 16_777_216, "depth" => 16}.freeze

    def self.encoded_batch_size(records, commit_id)
      envelopes = records.each_with_index.map { |record, index| {"commit_id" => commit_id, "record_index" => index, "record" => record} }
      JSON.generate({"domain" => records, "outbox" => envelopes}).bytesize
    end

    def self.copy(value)
      JSON.parse(JSON.generate(value))
    end

    def self.time(value)
      Timestamp.parse(value)
    end

    def self.dump_time(value)
      Timestamp.dump(time(value))
    end

    def self.sort_sets(sets)
      sets.sort_by { |set| set["group_id"] ? ["group", set["group_id"]] : ["unit", set.fetch("member_unit_ids").first] }
    end
  end
end
