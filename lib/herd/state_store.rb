# frozen_string_literal: true

require "sequel"

module Herd
  module StateStore
    Entry = Struct.new(:status, :stdout, :stderr, :value, :schema_version, :updated_at, keyword_init: true)

    # In-memory implementation primarily for testing.
    class Memory
      def initialize(clock: -> { Time.now })
        @clock = clock
        @store = {}
        @mutex = Mutex.new
      end

      def fetch(host:, task:, signature:, force: false)
        return nil if force

        synchronize { @store[key(host, task, signature)]&.dup }
      end

      def write(host:, task:, signature:, entry:)
        timestamped = entry.dup
        timestamped.updated_at = clock.call

        synchronize do
          @store[key(host, task, signature)] = timestamped
        end

        timestamped
      end

      def invalidate(host:, task:)
        synchronize do
          prefix = key_prefix(host, task)
          @store.keys.grep(/^#{Regexp.escape(prefix)}/).each do |entry_key|
            @store.delete(entry_key)
          end
        end
      end

      private

      attr_reader :clock

      def synchronize(&)
        @mutex.synchronize(&)
      end

      def key(host, task, signature)
        [host, task, signature].join(":")
      end

      def key_prefix(host, task)
        "#{[host, task].join(":")}:"
      end
    end

    # SQLite-backed persistent state store using Sequel.
    class SQLite
      TABLE_NAME = :state_entries

      def initialize(path:, clock: -> { Time.now })
        @clock = clock
        @db = Sequel.sqlite(path)
        migrate!
      end

      def fetch(host:, task:, signature:, force: false)
        return nil if force

        row = dataset.where(host: host, task: task, signature: signature).first
        return nil unless row

        build_entry(row)
      end

      def write(host:, task:, signature:, entry:)
        timestamp = clock.call

        payload = {
          host: host,
          task: task,
          signature: signature,
          status: entry.status.to_s,
          stdout: entry.stdout,
          stderr: entry.stderr,
          value: serialize(entry.value),
          schema_version: entry.schema_version,
          updated_at: timestamp
        }

        dataset.insert_conflict(target: %i[host task signature],
                                update: payload.except(:host, :task,
                                                       :signature)).insert(payload)

        fetch(host: host, task: task, signature: signature)
      end

      def invalidate(host:, task:)
        dataset.where(host: host, task: task).delete
      end

      def close
        db.disconnect
      end

      private

      attr_reader :clock, :db

      def dataset
        db[TABLE_NAME]
      end

      def migrate!
        db.create_table?(TABLE_NAME) do
          String :host, null: false
          String :task, null: false
          String :signature, null: false
          String :status, null: false
          Text :stdout
          Text :stderr
          Blob :value
          Integer :schema_version
          DateTime :updated_at, null: false

          primary_key %i[host task signature]
        end
      end

      def build_entry(row)
        Entry.new(
          status: row[:status].to_sym,
          stdout: row[:stdout],
          stderr: row[:stderr],
          value: deserialize(row[:value]),
          schema_version: row[:schema_version],
          updated_at: row[:updated_at]
        )
      end

      def serialize(value)
        return nil if value.nil?

        Sequel.blob(Marshal.dump(value))
      end

      def deserialize(blob)
        return nil if blob.nil?

        Marshal.load(blob.to_s)
      end
    end
  end
end
