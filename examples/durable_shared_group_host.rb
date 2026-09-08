# frozen_string_literal: true
require "json"
require "sqlite3"
require "securerandom"
require_relative "shared_group_host"

module RBBBExamples
  # Local SQLite reference adapter. The engine gem has no SQLite dependency.
  class DurableSharedGroupHost
    def initialize(path:, configurations:, clock:)
      @path = File.expand_path(path)
      @document = canonical({"format" => 1, "configurations" => configurations, "clock" => clock})
      build_host # Validate configuration before creating storage.
      begin
        File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |_| }
      rescue Errno::EEXIST
        stat = File.lstat(@path)
        unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
          raise ArgumentError, "database must be an owner-only regular file"
        end
      end
      transaction do |db|
        db.execute("CREATE TABLE IF NOT EXISTS metadata (id INTEGER PRIMARY KEY CHECK(id = 1), document TEXT NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS commits (sequence INTEGER PRIMARY KEY, command_id TEXT NOT NULL UNIQUE, request TEXT NOT NULL, result TEXT NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS delivery_stream (id INTEGER PRIMARY KEY CHECK(id = 1), identity TEXT NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS delivery_cursors (consumer TEXT PRIMARY KEY, sequence INTEGER NOT NULL)")
        db.execute("INSERT OR IGNORE INTO delivery_stream (id, identity) VALUES (1, ?)", [SecureRandom.uuid])
        saved = db.get_first_value("SELECT document FROM metadata WHERE id = 1")
        if saved
          raise ArgumentError, "stored configuration differs" unless saved == @document
        else
          db.execute("INSERT INTO metadata (id, document) VALUES (1, ?)", [@document])
        end
      end
    end

    def submit(unit_id:, command:, expected_revision:)
      transaction do |db|
        host = restore(db)
        request = host.send(:normalize_request, unit_id, command, expected_revision)
        receipt = host.submit(unit_id: request.fetch("unit_id"), command: request.fetch("command"),
          expected_revision: expected_revision)
        persist(db, request, receipt)
        receipt
      end
    end

    def close_group(command_id:, effective_at:, expected_revision:)
      transaction do |db|
        host = restore(db)
        request = host.send(:normalize_close_request, command_id, effective_at, expected_revision)
        receipt = dispatch(host, request)
        persist(db, request, receipt)
        receipt
      end
    end

    # One transaction returns both the revision and all member projections.
    def public_view
      transaction do |db|
        host = restore(db)
        snapshot = host.instance_variable_get(:@snapshot)
        {"clock" => snapshot.clock.public_view, "units" => host.public_view}
      end
    end

    # Journal commits are the outbox: no separate enqueue can be lost.
    def next_public_delivery(consumer_id:)
      consumer = delivery_consumer(consumer_id)
      transaction do |db|
        restore(db) # Validate committed results before exposing any projection.
        pending_delivery(db, consumer)
      end
    end

    def acknowledge_public_delivery(consumer_id:, delivery_id:)
      consumer = delivery_consumer(consumer_id)
      transaction do |db|
        restore(db)
        stream = db.get_first_value("SELECT identity FROM delivery_stream WHERE id = 1")
        unless delivery_id.is_a?(String) && delivery_id.match?(/\A#{Regexp.escape(stream)}:[1-9][0-9]*\z/)
          raise ArgumentError, "invalid delivery identity"
        end
        sequence = delivery_id.split(":").last.to_i
        cursor = db.get_first_value("SELECT sequence FROM delivery_cursors WHERE consumer = ?", [consumer]) || 0
        next false if sequence <= cursor
        pending = pending_delivery(db, consumer)
        unless pending && pending.fetch("delivery_id") == delivery_id
          raise ArgumentError, "only the next pending delivery can be acknowledged"
        end
        db.execute("INSERT INTO delivery_cursors (consumer, sequence) VALUES (?, ?) ON CONFLICT(consumer) DO UPDATE SET sequence = excluded.sequence", [consumer, sequence])
        true
      end
    end

    # Caller owns transport and sink deduplication. Never call under the DB lock.
    def deliver_next_public(consumer_id:)
      consumer_id = delivery_consumer(consumer_id)
      raise ArgumentError, "delivery callback required" unless block_given?
      payload = next_public_delivery(consumer_id: consumer_id)
      return nil unless payload
      identity = payload.fetch("delivery_id").dup.freeze
      yield payload
      acknowledge_public_delivery(consumer_id: consumer_id, delivery_id: identity)
      payload
    end

    private

    def delivery_consumer(value)
      raise ArgumentError, "consumer ID required" unless value.is_a?(String) && !value.empty?
      value.dup.freeze
    end

    def pending_delivery(db, consumer)
      cursor = db.get_first_value("SELECT sequence FROM delivery_cursors WHERE consumer = ?", [consumer]) || 0
      stream = db.get_first_value("SELECT identity FROM delivery_stream WHERE id = 1")
      db.execute("SELECT sequence, result FROM commits WHERE sequence > ? ORDER BY sequence", [cursor]).each do |sequence, json|
        result = JSON.parse(json)
        next if result["rejection"]
        # Explicit allowlist: never copy privileged events or receipt metadata.
        return {"delivery_id" => "#{stream}:#{sequence}",
          "clock" => result.fetch("clock"), "units" => result.fetch("units")}
      end
      nil
    end

    def build_host
      document = JSON.parse(@document)
      configs = document.fetch("configurations").transform_values { |v| RBBB::Configuration.from_h(v) }
      clock = RBBB::SharedClosingClock.new(**document.fetch("clock").transform_keys(&:to_sym))
      SharedGroupHost.new(configurations: configs, clock: clock)
    end

    def restore(db)
      unless db.get_first_value("SELECT document FROM metadata WHERE id = 1") == @document
        raise ArgumentError, "stored configuration differs"
      end
      host = build_host
      db.execute("SELECT command_id, request, result FROM commits ORDER BY sequence").each do |id, request_json, expected|
        request = JSON.parse(request_json)
        raise RBBB::InvalidState, "journal command identity mismatch" unless request.fetch("command").fetch("command_id") == id
        receipt = dispatch(host, request)
        unless canonical(receipt_document(receipt)) == expected
          raise RBBB::InvalidState, "journal replay differs from committed result"
        end
      end
      host
    end

    def persist(db, request, receipt)
      id = request.fetch("command").fetch("command_id")
      return if db.get_first_value("SELECT 1 FROM commits WHERE command_id = ?", [id])
      db.execute("INSERT INTO commits (command_id, request, result) VALUES (?, ?, ?)",
        [id, canonical(request), canonical(receipt_document(receipt))])
      before_commit(db)
    end

    def dispatch(host, request)
      case request["operation"]
      when nil
        host.submit(unit_id: request.fetch("unit_id"), command: request.fetch("command"),
          expected_revision: request.fetch("expected_revision"))
      when "close_group"
        host.close_group(command_id: request.fetch("command").fetch("command_id"),
          effective_at: request.fetch("command").fetch("effective_at"),
          expected_revision: request.fetch("expected_revision"))
      else
        raise RBBB::InvalidState, "unknown journal operation"
      end
    end

    def receipt_document(receipt)
      if receipt.is_a?(SharedGroupHost::CloseReceipt)
        return {"decisions" => receipt.decisions.transform_values { |decision|
          {"events" => decision.events.map { |event| {"visibility" => event.visibility.to_s, "data" => event.to_h} }}
        }, "clock" => receipt.clock, "units" => receipt.public_units}
      end
      {"events" => receipt.decision.events.map { |event| {"visibility" => event.visibility.to_s, "data" => event.to_h} },
        "rejection" => receipt.decision.rejection, "clock" => receipt.clock, "units" => receipt.public_units}
    end

    def canonical(value)
      normalized = JSON.parse(JSON.generate(value))
      sort = lambda do |item|
        case item
        when Hash then item.sort.to_h.transform_values { |v| sort.call(v) }
        when Array then item.map { |v| sort.call(v) }
        else item
        end
      end
      JSON.generate(sort.call(normalized))
    end

    def transaction
      db = SQLite3::Database.new(@path)
      db.busy_timeout = 5000
      db.execute("PRAGMA synchronous = FULL")
      db.execute("BEGIN IMMEDIATE")
      result = yield db
      db.execute("COMMIT")
      result
    rescue Exception
      db.execute("ROLLBACK") if db&.transaction_active?
      raise
    ensure
      db&.close
    end

    # Fault-injection seam: never deliver notifications before durable commit.
    def before_commit(_db)
    end
  end
end
