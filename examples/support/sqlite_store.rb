# frozen_string_literal: true

require "sqlite3"

module RBBBExamples
  # Shared SQLite file-safety and serialized-transaction helpers for local
  # reference adapters. The core engine gem has no SQLite dependency.
  module SqliteStore
    private

    def secure_file!
      File.open(@path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |_| }
    rescue Errno::EEXIST
      stat = File.lstat(@path)
      unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise ArgumentError, "database must be an owner-only regular file"
      end
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
  end
end
