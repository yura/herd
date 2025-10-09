# frozen_string_literal: true

require "fileutils"

module Herd
  # Central configuration object for Herd runtime.
  class Configuration
    attr_accessor :state_store_adapter, :state_store_path
    attr_reader :concurrency

    def initialize
      @state_store_adapter = ENV.key?("HERD_STATE_DB") ? :sqlite : nil
      @state_store_path = ENV.fetch("HERD_STATE_DB", default_state_store_path)
      self.concurrency = ENV.fetch("HERD_CONCURRENCY", nil)
    end

    def build_state_store(clock: -> { Time.now })
      case state_store_adapter
      when :sqlite
        ensure_directory(File.dirname(state_store_path))
        Herd::StateStore::SQLite.new(path: state_store_path, clock: clock)
      when :memory
        Herd::StateStore::Memory.new(clock: clock)
      when nil
        nil
      else
        raise ArgumentError, "Unknown state_store_adapter: #{state_store_adapter}"
      end
    end

    def concurrency=(value)
      numeric = value&.to_i
      @concurrency = numeric&.positive? ? numeric : nil
    end

    private

    def default_state_store_path
      File.join(Dir.home, ".herd", "state.sqlite3")
    rescue StandardError
      File.expand_path(".herd/state.sqlite3", Dir.pwd)
    end

    def ensure_directory(path)
      FileUtils.mkdir_p(path)
    end
  end
end
