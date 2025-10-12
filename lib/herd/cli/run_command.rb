# frozen_string_literal: true

module Herd
  # CLI namespace for command-line tooling.
  class CLI
    require "herd/report"
    require "herd/recipe"
    require "herd/runner"
    require "herd/progress_reporter"
    require "herd/hosts_loader"

    # Handles the `herd run` command.
    class RunCommand
      DEFAULT_USER = "root"
      DEFAULTS = {
        user: DEFAULT_USER,
        port: 22,
        timeout: 10
      }.freeze

      def initialize(argv)
        @argv = argv
        @options = {
          hosts_path: nil,
          user: DEFAULTS[:user],
          default_port: DEFAULTS[:port],
          default_timeout: DEFAULTS[:timeout]
        }
      end

      def execute
        recipe_path = consume_recipe_path!
        option_parser.order!(argv)
        ensure_hosts_provided!

        report = run_recipe(recipe_path)

        puts report.summary
        report.success? ? 0 : 1
      end

      private

      attr_reader :argv, :options

      def consume_recipe_path!
        recipe_path = argv.shift
        raise ArgumentError, "Recipe path is required" unless recipe_path

        recipe_path
      end

      def ensure_hosts_provided!
        return if options[:hosts_path]

        raise ArgumentError, "Hosts CSV is required (--hosts=PATH)"
      end

      def build_hosts
        Herd::HostsLoader.new(**host_loader_options).load
      end

      def run_recipe(recipe_path)
        recipe = Herd::Recipe.load(recipe_path)
        hosts = build_hosts
        runner = Herd::Runner.new(hosts)
        progress = Herd::ProgressReporter.new(hosts: hosts, recipe: recipe_label(recipe_path))
        report = Herd::Report.new

        recipe.run(runner, report: report, progress: progress)
      end

      def host_loader_options
        {
          path: options[:hosts_path],
          default_user: options[:user] || DEFAULT_USER,
          default_port: options[:default_port],
          default_timeout: options[:default_timeout]
        }
      end

      def recipe_label(path)
        File.basename(path, File.extname(path))
      end

      def option_parser
        OptionParser.new do |opts|
          configure_banner(opts)
          configure_hosts_option(opts)
          configure_user_option(opts)
          configure_port_option(opts)
          configure_timeout_option(opts)
          configure_help_option(opts)
        end
      end

      def configure_banner(opts)
        opts.banner = "Usage: herd run <recipe.rb> --hosts=hosts.csv [options]"
      end

      def configure_hosts_option(opts)
        opts.on("--hosts=PATH", "CSV file describing target hosts") do |value|
          options[:hosts_path] = value
        end
      end

      def configure_user_option(opts)
        opts.on("--user=USER", "Default SSH username (default: #{DEFAULTS[:user]})") do |value|
          options[:user] = value
        end
      end

      def configure_port_option(opts)
        opts.on("--port=PORT", Integer, "Default SSH port (default: #{DEFAULTS[:port]})") do |value|
          options[:default_port] = value
        end
      end

      def configure_timeout_option(opts)
        opts.on("--timeout=SECONDS", Integer, "SSH timeout per host (default: #{DEFAULTS[:timeout]})") do |value|
          options[:default_timeout] = value
        end
      end

      def configure_help_option(opts)
        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit 0
        end
      end
    end
  end
end
