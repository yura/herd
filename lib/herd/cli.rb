# frozen_string_literal: true

require "optparse"

module Herd
  # Minimal CLI for configuring Herd runtime options.
  class CLI
    attr_reader :options

    def initialize(argv)
      @options = {
        state_store: nil,
        state_path: nil
      }
      @argv = argv.dup
    end

    def parse!
      parser.parse!(@argv)
      normalize_options
      options
    end

    def apply!
      parse!

      Herd.configure do |config|
        if options[:state_store]
          config.state_store_adapter = options[:state_store]
        end

        if options[:state_path]
          config.state_store_path = options[:state_path]
        end
      end

      options
    end

    private

    attr_reader :argv

    def parser
      OptionParser.new do |opts|
        opts.banner = "Usage: herd [options]"

        opts.on("--state-store STORE", "Select state store adapter (sqlite, memory, none)") do |value|
          options[:state_store] = value
        end

        opts.on("--state-path PATH", "Path to SQLite state database") do |value|
          options[:state_path] = value
        end

        opts.on("--force", "Force rerun tasks (sets HERD_FORCE=true)") do
          ENV["HERD_FORCE"] = "1"
        end

        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end
    end

    def normalize_options
      if options[:state_store]
        options[:state_store] = normalize_store(options[:state_store])
      end
    end

    def normalize_store(store)
      case store
      when nil
        nil
      when "sqlite", :sqlite
        :sqlite
      when "memory", :memory
        :memory
      when "none", :none
        nil
      else
        raise OptionParser::InvalidArgument, "Unknown state store '#{store}'"
      end
    end
  end
end

