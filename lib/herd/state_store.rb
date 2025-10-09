# frozen_string_literal: true

require "thread"

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

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def key(host, task, signature)
        [host, task, signature].join(":")
      end

      def key_prefix(host, task)
        [host, task].join(":") + ":"
      end
    end
  end
end

