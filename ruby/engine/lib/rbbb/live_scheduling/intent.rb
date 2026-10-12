# frozen_string_literal: true

module RBBB
  module LiveScheduling
    # Closed untrusted submission boundary. Only integer JSON numbers are valid
    # in this contract, so canonicalization needs no floating-point coercion.
    module Intent
      class Invalid < ArgumentError; end
      class UniqueObject < Hash
        def []=(key, value)
          raise Invalid, "duplicate object key" if key?(key)
          super
        end
      end
      KEYS = %w[capability type command_id auction_id expected_schedule_revision expected_units reason allow_shortening resulting_closing_sets retired_group_ids].freeze
      module_function

      def parse(raw, profile: PROFILE)
        raise Invalid, "request size exceeded" unless raw.is_a?(String) && raw.bytesize <= profile.fetch("request_bytes")
        raise Invalid, "invalid UTF-8" unless raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        normalize(JSON.parse(raw, object_class: UniqueObject, max_nesting: profile.fetch("depth")))
      rescue JSON::ParserError, JSON::NestingError, EncodingError => e
        raise Invalid, e.message
      end

      def normalize(value)
        object(value, KEYS)
        raise Invalid, "unsupported submission" unless value["capability"] == CAPABILITY && %w[revise_closing_schedule reconfigure_closing_groups].include?(value["type"])
        %w[auction_id command_id].each { |k| identifier(value[k]) }
        revision(value["expected_schedule_revision"])
        reason = value["reason"]
        raise Invalid, "invalid reason" unless reason.is_a?(String) && reason.valid_encoding? && reason.length.between?(1, 2048) && reason.match?(/\S/)
        raise Invalid, "invalid shortening intent" unless [true, false].include?(value["allow_shortening"])
        units = array(value["expected_units"], minimum: 1)
        units.each { |v| object(v, %w[unit_id version]); identifier(v["unit_id"]); revision(v["version"]) }
        unique(units.map { |v| v["unit_id"] })
        sets = array(value["resulting_closing_sets"], minimum: 1).map { |set| normalize_set(set) }
        unique(sets.map { |set| set["group_id"] ? ["group", set["group_id"]] : ["unit", set["member_unit_ids"].first] })
        retired = array(value["retired_group_ids"], minimum: 0)
        retired.each { |id| identifier(id) }; unique(retired)
        raise Invalid, "schedule edit cannot retire groups" if value["type"] == "revise_closing_schedule" && !retired.empty?
        value.merge("expected_units" => units.sort_by { |v| v["unit_id"] },
          "resulting_closing_sets" => LiveScheduling.sort_sets(sets), "retired_group_ids" => retired.sort)
      rescue TypeError, NoMethodError, ArgumentError => e
        raise Invalid, e.message
      end

      def normalize_set(set)
        object(set, %w[group_id member_unit_ids closes_at extension])
        identifier(set["group_id"]) unless set["group_id"].nil?
        ids = array(set["member_unit_ids"], minimum: 1)
        ids.each { |id| identifier(id) }; unique(ids)
        raise Invalid, "ungrouped set needs one unit" if set["group_id"].nil? && ids.size != 1
        extension = set["extension"]
        unless extension.nil?
          object(extension, %w[trigger_window_seconds duration_seconds])
          revision(extension["trigger_window_seconds"])
          revision(extension["duration_seconds"])
          raise Invalid, "invalid duration" unless extension["duration_seconds"].positive?
        end
        at = LiveScheduling.time(set["closes_at"])
        set.merge("member_unit_ids" => ids.sort, "closes_at" => at.utc.iso8601(3))
      end

      def fingerprint(principal, intent)
        identifier(principal)
        Digest::SHA256.hexdigest(canonical({"principal_id" => principal, "intent" => intent}))
      end

      # RFC 8785 sorts object property names by UTF-16 code units, not Ruby's
      # Unicode scalar order. Reasons are preserved verbatim, never normalized.
      def canonical(value)
        case value
        when Hash
          "{" + value.keys.sort_by { |k| k.encode(Encoding::UTF_16BE).bytes }.map { |k| JSON.generate(k) + ":" + canonical(value.fetch(k)) }.join(",") + "}"
        when Array then "[" + value.map { |v| canonical(v) }.join(",") + "]"
        when String
          raise Invalid, "invalid string" unless value.encoding.ascii_compatible? && value.valid_encoding?
          JSON.generate(value.encode(Encoding::UTF_8))
        when Integer
          raise Invalid, "unsafe integer" unless value.abs <= MAX_SAFE_INTEGER
          value.to_s
        when TrueClass, FalseClass, NilClass then JSON.generate(value)
        else raise Invalid, "unsupported JSON value"
        end
      end

      def identifier(value)
        raise Invalid, "invalid identifier" unless value.is_a?(String) && value.length.between?(1, 128) && value.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      end

      def revision(value)
        raise Invalid, "invalid revision" unless value.is_a?(Integer) && value.between?(0, MAX_SAFE_INTEGER)
      end

      def object(value, keys)
        raise Invalid, "invalid object properties" unless value.is_a?(Hash) && value.keys.sort == keys.sort
      end

      def array(value, minimum:)
        raise Invalid, "invalid array" unless value.is_a?(Array) && value.size >= minimum && value.size <= 4096
        value
      end

      def unique(values)
        raise Invalid, "duplicate set member" unless values.uniq.size == values.size
      end
    end
  end
end
