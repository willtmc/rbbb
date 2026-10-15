# frozen_string_literal: true

require "json"
require "securerandom"
require "sqlite3"
require "rbbb"
require "rbbb/live_scheduling"

module RBBBExamples
  # Embedded SQLite reference host, not an HTTP endpoint. Principal/permissions
  # must come from the host's authenticated context. BEGIN IMMEDIATE fences all
  # writes across connections/processes (stronger than an auction-row lock).
  # Snapshot/receipts are privileged; never expose them directly to a bidder.
  class LiveSchedulingHost
    class ResponseLost < StandardError; end
    attr_reader :auction_id, :tenant_id

    def initialize(path:, tenant_id:, auction_id:, configurations:, snapshot:, policy:, clock:, profile: RBBB::LiveScheduling::PROFILE)
      @path = File.expand_path(path)
      @tenant_id, @auction_id, @clock = tenant_id, auction_id, clock
      @profile = RBBB::LiveScheduling.copy(profile)
      RBBB::LiveScheduling::Intent.identifier(tenant_id)
      initial = RBBB::LiveScheduling::Coordinator.new(auction_id: auction_id, configurations: configurations,
        snapshot: snapshot, policy: policy, profile: profile)
      @configuration = JSON.generate({"configurations" => configurations, "policy" => policy, "profile" => profile})
      secure_file!
      transaction do |db|
        db.execute("CREATE TABLE IF NOT EXISTS auctions (tenant TEXT NOT NULL, auction TEXT NOT NULL, configuration TEXT NOT NULL, state TEXT NOT NULL, retired TEXT NOT NULL, sealed INTEGER NOT NULL DEFAULT 0, last_time TEXT, sequence INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (tenant, auction))")
        db.execute("CREATE TABLE IF NOT EXISTS receipts (tenant TEXT NOT NULL, auction TEXT NOT NULL, command TEXT NOT NULL, principal TEXT NOT NULL, fingerprint TEXT NOT NULL, response TEXT NOT NULL, PRIMARY KEY (tenant, auction, command))")
        db.execute("CREATE TABLE IF NOT EXISTS commits (tenant TEXT NOT NULL, auction TEXT NOT NULL, sequence INTEGER NOT NULL, commit_id TEXT NOT NULL UNIQUE, records TEXT NOT NULL, PRIMARY KEY (tenant, auction, sequence))")
        db.execute("CREATE TABLE IF NOT EXISTS outbox (commit_id TEXT NOT NULL, record_index INTEGER NOT NULL, record TEXT NOT NULL, delivered INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (commit_id, record_index))")
        existing = row(db)
        if existing
          validate_stored_configuration!(existing[0])
          validate_retained_history!(db, existing)
        else
          last = snapshot.fetch("units").values.filter_map { |unit| unit["last_effective_at"] }.max_by { |at| RBBB::Timestamp.parse(at) }
          db.execute("INSERT INTO auctions (tenant, auction, configuration, state, retired, last_time) VALUES (?, ?, ?, ?, ?, ?)",
            [tenant_id, auction_id, @configuration, JSON.generate(initial.snapshot), "[]", last])
        end
      end
    end

    def edit(intent:, principal_id:, permissions:)
      normalized = if intent.is_a?(String)
        RBBB::LiveScheduling::Intent.parse(intent, profile: @profile)
      else
        RBBB::LiveScheduling::Intent.parse(JSON.generate(intent), profile: @profile)
      end
      raise ArgumentError, "wrong auction" unless normalized["auction_id"] == auction_id
      submit({"kind" => "edit", "intent" => normalized}, principal_id, permissions)
    end

    def register_unit(intent:, principal_id:, permissions:)
      raw = intent.is_a?(String) ? intent : JSON.generate(intent)
      normalized = RBBB::LiveScheduling::Intent.parse_registration(raw, profile: @profile)
      raise ArgumentError, "wrong auction" unless normalized["auction_id"] == auction_id
      submit({"kind" => "register", "intent" => normalized}, principal_id, permissions)
    end

    # Privileged registry read for durable replay/integration, not public output.
    def configurations
      transaction { |db| RBBB::LiveScheduling.copy(JSON.parse(row(db)[0]).fetch("configurations")) }
    end

    def bid(unit_id:, command:, principal_id:)
      # The bidder's identity and authoritative time are never submitted fields.
      raise ArgumentError, "server-assigned fields" if command.key?("effective_at") || command.key?("bidder_id")
      RBBB::LiveScheduling::Intent.identifier(unit_id)
      RBBB::LiveScheduling::Intent.identifier(principal_id)
      allowed = %w[type command_id maximum_minor_units bid_id]
      raise ArgumentError, "unknown bid property" unless (command.keys - allowed).empty?
      raise ArgumentError, "unsupported bid operation" unless %w[place_bid reduce_maximum].include?(command["type"])
      RBBB::LiveScheduling::Intent.identifier(command["command_id"])
      submit({"kind" => "bid", "unit_id" => unit_id, "command" => command}, principal_id, ["bid"])
    end

    def void_bid(unit_id:, command:, principal_id:, permissions:)
      RBBB::LiveScheduling::Intent.identifier(unit_id)
      RBBB::LiveScheduling::Intent.identifier(principal_id)
      allowed = %w[type command_id bid_id reason notification_policy]
      raise ArgumentError, "unknown void property" unless (command.keys - allowed).empty?
      raise ArgumentError, "unsupported void operation" unless command["type"] == "void_bid"
      RBBB::LiveScheduling::Intent.identifier(command["command_id"])
      submit({"kind" => "void", "unit_id" => unit_id, "command" => command}, principal_id, permissions)
    end

    def change_reserve(unit_id:, command:, principal_id:, permissions:)
      RBBB::LiveScheduling::Intent.identifier(unit_id)
      RBBB::LiveScheduling::Intent.identifier(principal_id)
      allowed = %w[type command_id reserve_minor_units reason notification_policy]
      raise ArgumentError, "unknown reserve property" unless (command.keys - allowed).empty?
      raise ArgumentError, "unsupported reserve operation" unless command["type"] == "change_reserve"
      RBBB::LiveScheduling::Intent.identifier(command["command_id"])
      submit({"kind" => "reserve", "unit_id" => unit_id, "command" => command}, principal_id, permissions)
    end

    def close(group_id: nil, unit_id: nil, command_id:, principal_id:, permissions:)
      raise ArgumentError, "choose exactly one closing set" unless !!group_id != !!unit_id
      RBBB::LiveScheduling::Intent.identifier(group_id || unit_id)
      RBBB::LiveScheduling::Intent.identifier(command_id)
      submit({"kind" => "close", "group_id" => group_id, "unit_id" => unit_id,
        "command" => {"type" => "close_bidding", "command_id" => command_id}}, principal_id, permissions)
    end

    # Sealing and reads share the same database ordering boundary. There is no
    # unseal shortcut: restoring mutation must restore the complete receipt index.
    def seal!
      transaction { |db| db.execute("UPDATE auctions SET sealed = 1 WHERE tenant = ? AND auction = ?", [tenant_id, auction_id]) }
    end

    def snapshot
      transaction { |db| JSON.parse(row(db)[1]) }
    end

    def public_view
      snapshot.fetch("units").transform_values { |unit| RBBB::State.from_h(unit).public_view }
    end

    def records
      transaction { |db| db.execute("SELECT records FROM commits WHERE tenant = ? AND auction = ? ORDER BY sequence", [tenant_id, auction_id]).flat_map { |entry| JSON.parse(entry[0]) } }
    end

    def receipt_count
      transaction { |db| db.get_first_value("SELECT COUNT(*) FROM receipts WHERE tenant = ? AND auction = ?", [tenant_id, auction_id]) }
    end

    # Privileged integration seam: publish one complete committed batch outside
    # the transaction; acknowledgement never reruns its scheduling mutation.
    # Delivery is at least once. The consumer deduplicates (commit_id, index).
    def deliver_pending
      batches = transaction do |db|
        db.execute("SELECT c.commit_id, c.records FROM commits c WHERE c.tenant = ? AND c.auction = ? AND EXISTS (SELECT 1 FROM outbox o WHERE o.commit_id = c.commit_id AND o.delivered = 0) ORDER BY c.sequence", [tenant_id, auction_id])
      end
      batches.each do |commit_id, encoded|
        batch = JSON.parse(encoded).each_with_index.map { |record, index| {"commit_id" => commit_id, "record_index" => index, "record" => record} }
        yield batch
        before_delivery_ack(commit_id)
        transaction { |db| db.execute("UPDATE outbox SET delivered = 1 WHERE commit_id = ?", [commit_id]) }
      end
      batches.size
    end

    private

    def submit(request, principal, permissions)
      RBBB::LiveScheduling::Intent.identifier(principal)
      fingerprint = RBBB::LiveScheduling::Intent.fingerprint(principal, request)
      command_id = request.fetch(%w[edit register].include?(request["kind"]) ? "intent" : "command").fetch("command_id")
      response = transaction do |db|
        validate_retained_history!(db, row(db))
        saved = db.get_first_row("SELECT principal, fingerprint, response FROM receipts WHERE tenant = ? AND auction = ? AND command = ?", [tenant_id, auction_id, command_id])
        required = {"edit" => "schedule", "register" => "register", "bid" => "bid", "void" => "void", "reserve" => "reserve", "close" => "close"}.fetch(request["kind"])
        if saved
          next rejection("not_authorized") unless saved[0] == principal && permissions.include?(required)
          next rejection("command_id_reused").merge("receipt_retained" => true) unless saved[1] == fingerprint
          next JSON.parse(saved[2]).merge("replayed" => true)
        end
        config, state_json, retired_json, sealed, last_time, sequence = row(db)
        validate_stored_configuration!(config)
        document = JSON.parse(config)
        state = JSON.parse(state_json)
        observed = RBBB::Timestamp.parse(@clock.call)
        at = last_time ? [observed, RBBB::Timestamp.parse(last_time)].max : observed
        clock_rollback(observed, at) if at > observed
        coordinator = RBBB::LiveScheduling::Coordinator.new(auction_id: auction_id,
          configurations: document["configurations"], snapshot: state, policy: document["policy"],
          profile: document["profile"], retired_group_ids: JSON.parse(retired_json))
        commit_id = next_commit_id
        result = if sealed == 1
          coordinator.send(:reject, "auction_sealed")
        elsif !permissions.include?(required)
          coordinator.send(:reject, "not_authorized")
        else
          case request["kind"]
          when "register"
            coordinator.register_unit(intent: request["intent"], principal_id: principal, permissions: permissions, effective_at: at, commit_id: commit_id)
          when "edit"
            coordinator.edit(intent: request["intent"], principal_id: principal, permissions: permissions, effective_at: at, commit_id: commit_id)
          when "bid"
            coordinator.bid(unit_id: request["unit_id"], command: request["command"].merge("bidder_id" => principal), effective_at: at, commit_id: commit_id)
          when "void"
            coordinator.void_bid(unit_id: request["unit_id"], command: request["command"].merge("operator_id" => principal), effective_at: at, commit_id: commit_id)
          when "reserve"
            coordinator.change_reserve(unit_id: request["unit_id"], command: request["command"].merge("operator_id" => principal), effective_at: at, commit_id: commit_id)
          when "close"
            coordinator.close(group_id: request["group_id"], unit_id: request["unit_id"], command: request["command"], effective_at: at, commit_id: commit_id)
          end
        end
        rejection_document = if %w[edit register].include?(request['kind']) && result.rejection_reason
          {"capability" => RBBB::LiveScheduling::CAPABILITY, "type" => "closing_change_rejected",
            "command_id" => command_id, "reason" => result.rejection_reason}
        end
        response = {"rejection" => rejection_document, "rejection_reason" => result.rejection_reason, "records" => result.records,
          "effective_at" => RBBB::Timestamp.dump(at), "commit_id" => result.rejection_reason ? nil : commit_id,
          "receipt_retained" => true, "replayed" => false}
        document["configurations"] = result.configurations if result.configurations && !result.rejection_reason
        db.execute("UPDATE auctions SET configuration = ?, state = ?, retired = ?, last_time = ?, sequence = ? WHERE tenant = ? AND auction = ?",
          [JSON.generate(document), result.rejection_reason ? state_json : JSON.generate(result.state),
            result.rejection_reason ? retired_json : JSON.generate(result.retired_group_ids),
            RBBB::Timestamp.dump(at), sequence + 1, tenant_id, auction_id])
        unless result.records.empty?
          db.execute("INSERT INTO commits VALUES (?, ?, ?, ?, ?)", [tenant_id, auction_id, sequence + 1, commit_id, JSON.generate(result.records)])
          result.records.each_with_index do |record, index|
            db.execute("INSERT INTO outbox (commit_id, record_index, record) VALUES (?, ?, ?)", [commit_id, index, JSON.generate(record)])
          end
        end
        db.execute("INSERT INTO receipts VALUES (?, ?, ?, ?, ?, ?)", [tenant_id, auction_id, command_id, principal, fingerprint, JSON.generate(response)])
        before_commit(db)
        response
      end
      after_commit(response)
      response
    end

    def validate_stored_configuration!(encoded)
      stored, bootstrap = JSON.parse(encoded), JSON.parse(@configuration)
      same_policy = %w[policy profile].all? { |key| stored[key] == bootstrap[key] }
      same_seed = bootstrap.fetch("configurations").all? { |id, config| stored.fetch("configurations")[id] == config }
      raise ArgumentError, "stored configuration differs" unless same_policy && same_seed
    end

    # A partial archive must not silently turn retained command IDs into fresh
    # decisions. This reference-host consistency check detects missing registry,
    # receipts, commits or outbox rows; it is not an authenticated archive manifest
    # and cannot detect a coordinated rewrite of all copies of the evidence.
    def validate_retained_history!(db, stored)
      config, state, _retired, _sealed, _last_time, sequence = stored
      registry = JSON.parse(config).fetch("configurations")
      units = JSON.parse(state).fetch("units")
      valid = registry.keys.sort == units.keys.sort
      receipts = db.execute("SELECT response FROM receipts WHERE tenant = ? AND auction = ?", [tenant_id, auction_id])
      valid &&= receipts.size == sequence
      accepted = receipts.map { |entry| JSON.parse(entry[0]) }.reject { |response| response["rejection_reason"] }
      commits = db.execute("SELECT commit_id, records FROM commits WHERE tenant = ? AND auction = ?", [tenant_id, auction_id])
      # Successful no-event operations can have a receipt without a journal batch.
      journaled = accepted.reject { |response| response.fetch("records").empty? }
      valid &&= commits.size == journaled.size
      valid &&= commits.all? do |commit_id, encoded|
        matching = journaled.select { |response| response["commit_id"] == commit_id }
        records = JSON.parse(encoded)
        outbox = db.execute("SELECT record_index, record FROM outbox WHERE commit_id = ? ORDER BY record_index", [commit_id])
        matching.size == 1 && matching.first.fetch("records") == records &&
          outbox == records.each_with_index.map { |record, index| [index, JSON.generate(record)] }
      end
      raise RBBB::InvalidState, "incomplete retained registry or history" unless valid
    rescue JSON::ParserError, KeyError, TypeError
      raise RBBB::InvalidState, "invalid retained registry or history"
    end

    def rejection(reason)
      {"rejection_reason" => reason, "records" => [], "receipt_retained" => false, "replayed" => false}
    end

    def row(db)
      db.get_first_row("SELECT configuration, state, retired, sealed, last_time, sequence FROM auctions WHERE tenant = ? AND auction = ?", [tenant_id, auction_id])
    end

    def secure_file!
      File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |_| }
    rescue Errno::EEXIST
      stat = File.lstat(@path)
      raise ArgumentError, "database must be an owner-only regular file" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
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

    def before_commit(_db); end
    def after_commit(_response); end
    def clock_rollback(_observed, _ordered)
      warn "[LiveSchedulingHost] authoritative clock rollback clamped"
    end
    def before_delivery_ack(_commit_id); end
    def next_commit_id = SecureRandom.uuid
  end
end
