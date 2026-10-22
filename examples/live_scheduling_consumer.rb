# frozen_string_literal: true

require "sqlite3"
require_relative "live_scheduling_reader"

module RBBBExamples
  # Local, trusted snapshot replacement example. No incremental replay API.
  # The fetch callback MUST authenticate/authorize each call and return only its
  # authorized projection. A digest is integrity bookkeeping, not authentication.
  class LiveSchedulingConsumer
    class InvalidCheckpoint < StandardError; end

    def initialize(path:, tenant_id:, auction_id:, visibility:, fetch:)
      raise ArgumentError, "unsupported visibility" unless %w[public privileged].include?(visibility)
      @path, @tenant, @auction, @visibility, @fetch = path, tenant_id, auction_id, visibility, fetch
      File.open(path, File::RDWR | File::CREAT, 0o600) {} unless File.exist?(path)
      File.chmod(0o600, path)
      transaction do |db|
        db.execute("CREATE TABLE IF NOT EXISTS installation (slot INTEGER PRIMARY KEY CHECK(slot = 1), document TEXT NOT NULL)")
      end
    end

    # There is deliberately no offline read: serving always reauthorizes/refetches.
    # Never serve an old row after an authorization failure or failed refetch.
    def read(credential:)
      result = @fetch.call(credential: credential, visibility: @visibility)
      result = JSON.parse(JSON.generate(result)) # detached trusted callback result
      validate!(result)
      transaction do |db|
        stored = db.get_first_value("SELECT document FROM installation WHERE slot = 1")
        previous = stored && JSON.parse(stored)
        if previous
          validate!(previous)
          if identity(previous) == identity(result) && previous != result
            raise InvalidCheckpoint, "conflicting checkpoint"
          end
        end
        unless previous == result
          db.execute("INSERT OR REPLACE INTO installation(slot, document) VALUES (1, ?)", [JSON.generate(result)])
          before_install_commit
        end
      end
      after_install_commit
      result
    rescue LiveSchedulingReader::NotAuthorized
      transaction { |db| db.execute("DELETE FROM installation") }
      raise
    end

    private

    def identity(result)
      payload = result.fetch("payload")
      payload.values_at("tenant_id", "auction_id", "visibility", "authorization_context", "decision_sequence")
    end

    def validate!(result)
      raise InvalidCheckpoint, "invalid checkpoint" unless result.is_a?(Hash) && result.keys.sort == %w[payload sha256]
      payload = result["payload"]
      unless payload.is_a?(Hash) && payload.keys.sort == %w[auction_id authorization_context decision_sequence snapshot tenant_id visibility] &&
          payload["tenant_id"] == @tenant && payload["auction_id"] == @auction && payload["visibility"] == @visibility &&
          payload["authorization_context"].is_a?(String) && !payload["authorization_context"].empty? &&
          payload["decision_sequence"].is_a?(Integer) && payload["decision_sequence"] >= 0 && payload["snapshot"].is_a?(Hash)
        raise InvalidCheckpoint, "invalid scope or checkpoint"
      end
      unless result["sha256"] == Digest::SHA256.hexdigest(JSON.generate(payload))
        raise InvalidCheckpoint, "invalid digest"
      end
    end

    def transaction
      db = SQLite3::Database.new(@path)
      db.busy_timeout = 5000
      db.execute("PRAGMA synchronous = FULL")
      db.execute("BEGIN IMMEDIATE")
      value = yield db
      db.execute("COMMIT")
      value
    rescue Exception
      db&.execute("ROLLBACK") if db&.transaction_active?
      raise
    ensure
      db&.close
    end

    # Fault hooks for synthetic tests; no external effects.
    def before_install_commit; end
    def after_install_commit; end
  end
end
