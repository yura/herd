# frozen_string_literal: true

require "optparse"
require "json"
require "yaml"

require "herd/report_writer"

module Herd
  # Minimal CLI for configuring Herd runtime options.
  class CLI
    attr_reader :options, :commands

    # @param argv [Array<String>] raw command line arguments to parse.
    def initialize(argv)
      @options = {
        state_store: nil,
        state_path: nil
      }
      @commands = []
      @argv = argv.dup
    end

    # Parses global options without mutating configuration.
    #
    # @return [Hash] normalized options hash.
    def parse!
      parse_global_options!
      normalize_options
      options
    end

    # Applies parsed configuration to {Herd.configuration}.
    #
    # @return [Hash] effective options.
    def apply!
      parse!

      Herd.configure do |config|
        config.state_store_adapter = options[:state_store] if options[:state_store]

        config.state_store_path = options[:state_path] if options[:state_path]
      end

      options
    end

    # Executes the selected subcommand (currently only `run`).
    #
    # @return [Hash, void] options hash when no subcommand is given.
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

    # Parses options that apply before subcommand dispatch.
    #
    # @return [void]
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

    # Builds the OptionParser for top-level flags.
    #
    # @return [OptionParser]
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

    # Normalizes option values (e.g., converts store names to symbols).
    #
    # @return [void]
    def normalize_options
      return unless options[:state_store]

      options[:state_store] = normalize_store(options[:state_store])
    end

    # Converts user input into a supported state store symbol.
    #
    # @param store [String, Symbol, nil]
    # @return [Symbol, nil]
    def normalize_store(store)
      return nil if store.nil?

      normalized = store.to_s
      return nil if normalized == "none"

      case normalized
      when "sqlite"
        :sqlite
      when "memory"
        :memory
      else
        raise OptionParser::InvalidArgument, "Unknown state store '#{store}'"
      end
    end

    # Executes the `run` subcommand.
    #
    # @param args [Array<String>] command arguments (mutated while parsing).
    # @return [void]
    def run_recipe(args)
      command_options = {
        hosts: [],
        params: {},
        context: {},
        params_files: [],
        concurrency: nil,
        report_summary: nil,
        report_json: nil,
        force: ENV["HERD_FORCE"] == "1"
      }

      recipe_path = parse_run_options!(args, command_options)
      recipe = load_recipe(recipe_path)

      apply_params_files(command_options)

      hosts = command_options[:hosts]
      hosts = ["localhost"] if hosts.empty?

      state_store = Herd.configuration.build_state_store
      results = hosts.map do |host|
        context = command_options[:context].dup
        context[:host] ||= host
        context[:params] ||= command_options[:params]
        result = recipe.run(
          host: host,
          params: command_options[:params],
          context: context,
          force: command_options[:force],
          state_store: state_store,
          concurrency: command_options[:concurrency]
        )
        [host, result]
      end

      puts recipe.report.summary
      results.each do |host, result|
        puts "Host #{host}: #{result.success? ? "success" : "fail"}"
      end

      Herd::ReportWriter.write(
        recipe.report,
        summary_path: command_options[:report_summary],
        json_path: command_options[:report_json]
      )

      state_store&.close if state_store.respond_to?(:close)
    end

    # Parses flags specific to the `run` subcommand.
    #
    # @param args [Array<String>] positional + flag arguments.
    # @param command_options [Hash] accumulator for parsed options.
    # @return [String] recipe path.
    def parse_run_options!(args, command_options)
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: herd run <recipe.rb> [options]"

        opts.on("--host HOSTS", "Target host(s), comma-separated or repeatable") do |value|
          command_options[:hosts].concat(split_hosts(value))
        end

        opts.on("--param KEY=VALUE", "Runtime parameter") do |pair|
          key, value = parse_key_value(pair)
          command_options[:params][key.to_sym] = value
        end

        opts.on("--context KEY=VALUE", "Context value passed to tasks") do |pair|
          key, value = parse_key_value(pair)
          command_options[:context][key.to_sym] = value
        end

        opts.on("--params-file PATH", "Load runtime parameters from JSON or YAML file") do |path|
          command_options[:params_files] << path
        end

        opts.on("--report-summary PATH", "Write summary report to PATH") do |path|
          command_options[:report_summary] = path
        end

        opts.on("--report-json PATH", "Write JSON report to PATH") do |path|
          command_options[:report_json] = path
        end

        opts.on("--concurrency N", Integer, "Run up to N tasks in parallel") do |value|
          command_options[:concurrency] = value
        end

        opts.on("--force", "Force rerun tasks") do
          command_options[:force] = true
        end
      end

      path = args.shift
      raise ArgumentError, "Recipe path required" unless path

      parser.order!(args)

      path
    end

    # Splits KEY=VALUE strings.
    #
    # @param pair [String]
    # @return [Array<(String, String)>]
    def parse_key_value(pair)
      key, value = pair.split("=", 2)
      raise OptionParser::InvalidArgument, "Expected KEY=VALUE, got '#{pair}'" if key.nil? || value.nil?

      [key, value]
    end

    # Loads a recipe file using the DSL loader.
    #
    # @param path [String]
    # @return [Herd::DSL::Recipe]
    def load_recipe(path)
      Herd::DSL.load_file(path)
    end

    # Merges parameters from provided files into command options.
    #
    # @param command_options [Hash]
    # @return [void]
    def apply_params_files(command_options)
      command_options[:params_files].each do |path|
        data = load_params_file(path)
        command_options[:params] = data.merge(command_options[:params])
      end
    end

    # Parses comma-separated host lists.
    #
    # @param value [String]
    # @return [Array<String>]
    def split_hosts(value)
      value.split(",").map(&:strip).reject(&:empty?)
    end

    # Loads a params file in JSON or YAML format.
    #
    # @param path [String]
    # @return [Hash]
    def load_params_file(path)
      content = File.read(path)
      case File.extname(path)
      when ".json"
        JSON.parse(content)
      when ".yml", ".yaml"
        YAML.safe_load(content, aliases: true) || {}
      else
        begin
          JSON.parse(content)
        rescue JSON::ParserError
          YAML.safe_load(content, aliases: true) || {}
        end
      end.transform_keys(&:to_sym)
    end

    # Consumes the next argv value or raises when missing.
    #
    # @param flag [String] flag name for error reporting.
    # @return [String]
    def shift_required(flag)
      value = argv.shift
      raise OptionParser::MissingArgument, flag unless value

      value
    end
  end
end
