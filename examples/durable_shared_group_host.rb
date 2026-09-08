# frozen_string_literal: true
require "json"
require "sqlite3"
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
        id = request.fetch("command").fetch("command_id")
        unless db.get_first_value("SELECT 1 FROM commits WHERE command_id = ?", [id])
          db.execute("INSERT INTO commits (command_id, request, result) VALUES (?, ?, ?)",
            [id, canonical(request), canonical(receipt_document(receipt))])
          before_commit(db)
        end
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

    private

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
        receipt = host.submit(unit_id: request.fetch("unit_id"), command: request.fetch("command"),
          expected_revision: request.fetch("expected_revision"))
        unless canonical(receipt_document(receipt)) == expected
          raise RBBB::InvalidState, "journal replay differs from committed result"
        end
      end
      host
    end

    def receipt_document(receipt)
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
