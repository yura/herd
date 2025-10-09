# frozen_string_literal: true

require "optparse"

module Herd
  # Minimal CLI for configuring Herd runtime options.
  class CLI
    attr_reader :options, :commands

    def initialize(argv)
      @options = {
        state_store: nil,
        state_path: nil
      }
      @commands = []
      @argv = argv.dup
    end

    def parse!
      parse_global_options!
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

    def run!
      apply!

      return options if commands.empty?

      command = commands.shift
      case command
      when "run"
        run_recipe(commands)
      else
        warn "Unknown command: #{command}"
        exit 1
      end
    end

    private

    attr_reader :argv

    def parse_global_options!
      while argv.any?
        arg = argv.first

        case arg
        when "--"
          argv.shift
          commands.concat(argv)
          argv.clear
          break
        when "--state-store"
          argv.shift
          options[:state_store] = shift_required("--state-store")
        when /\A--state-store=(.+)/
          argv.shift
          options[:state_store] = Regexp.last_match(1)
        when "--state-path"
          argv.shift
          options[:state_path] = shift_required("--state-path")
        when /\A--state-path=(.+)/
          argv.shift
          options[:state_path] = Regexp.last_match(1)
        when "--force"
          argv.shift
          ENV["HERD_FORCE"] = "1"
        when "-h", "--help"
          argv.shift
          puts parser
          exit 0
        when /^-/
          raise OptionParser::InvalidOption, arg
        else
          commands.concat(argv)
          argv.clear
          break
        end
      end
    end

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

    def run_recipe(args)
      command_options = {
        hosts: [],
        params: {},
        context: {},
        force: ENV["HERD_FORCE"] == "1"
      }

      recipe_path = parse_run_options!(args, command_options)
      recipe = load_recipe(recipe_path)

      hosts = command_options[:hosts]
      hosts = ["localhost"] if hosts.empty?

      state_store = Herd.configuration.build_state_store
      results = hosts.map do |host|
        context = command_options[:context].dup
        result = recipe.run(
          host: host,
          params: command_options[:params],
          context: context,
          force: command_options[:force],
          state_store: state_store
        )
        [host, result]
      end

      puts recipe.report.summary
      results.each do |host, result|
        puts "Host #{host}: #{result.success? ? 'success' : 'fail'}"
      end

      state_store&.close if state_store.respond_to?(:close)
    end

    def parse_run_options!(args, command_options)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: herd run <recipe.rb> [options]"

        opts.on("--host HOST", "Target host (repeatable)") do |value|
          command_options[:hosts] << value
        end

        opts.on("--param KEY=VALUE", "Runtime parameter") do |pair|
          key, value = parse_key_value(pair)
          command_options[:params][key.to_sym] = value
        end

        opts.on("--context KEY=VALUE", "Context value passed to tasks") do |pair|
          key, value = parse_key_value(pair)
          command_options[:context][key.to_sym] = value
        end

        opts.on("--force", "Force rerun tasks") do
          command_options[:force] = true
        end
      end

      path = args.shift
      raise ArgumentError, "Recipe path required" unless path

      parser.order!(args)
      raise ArgumentError, "Recipe path required" unless path

      path
    end

    def parse_key_value(pair)
      key, value = pair.split("=", 2)
      raise OptionParser::InvalidArgument, "Expected KEY=VALUE, got '#{pair}'" if key.nil? || value.nil?

      [key, value]
    end

    def load_recipe(path)
      code = File.read(path)
      recipe = Kernel.eval(code, TOPLEVEL_BINDING, path)
      unless recipe.is_a?(Herd::DSL::Recipe)
        raise ArgumentError, "Recipe #{path} must return Herd::DSL::Recipe"
      end
      recipe
    end

    def shift_required(flag)
      value = argv.shift
      raise OptionParser::MissingArgument, flag unless value

      value
    end
  end
end
