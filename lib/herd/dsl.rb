# frozen_string_literal: true

module Herd
  # Ruby DSL for defining dependency-aware deployment recipes.
  module DSL
    # Builder collects task declarations for a recipe.
    class Builder
      attr_reader :tasks, :report

      def initialize
        @tasks = []
        @defaults = {}
        @report = Herd::RunReport.new
      end

      # Returns current defaults or merges the provided hash into defaults.
      #
      # @param values [Hash, nil] default context/params.
      # @return [Hash]
      def defaults(values = nil)
        return @defaults.dup if values.nil?

        @defaults.merge!(values)
      end

      # Adds a task definition to the recipe builder.
      #
      # @param name [String, Symbol]
      # @param depends_on [Array<String, Symbol>] list of prerequisite task names.
      # @param options [Hash] extra task options (e.g., signature params).
      # @yield [context] block executed when the task runs.
      # @return [void]
      def task(name, depends_on: [], **options, &block)
        raise ArgumentError, "block required for task #{name}" unless block

        tasks << {
          name: name.to_s,
          depends_on: Array(depends_on).map(&:to_s),
          options: options,
          block: block
        }
      end

      # Finalizes the builder into a {Recipe}.
      #
      # @return [Recipe]
      def build
        Recipe.new(tasks: tasks, defaults: @defaults.dup, report: report)
      end
    end

    # Recipe wraps a TaskGraph with predefined tasks and defaults.
    class Recipe
      attr_reader :tasks, :defaults, :report

      def initialize(tasks:, defaults:, report: Herd::RunReport.new)
        @tasks = tasks
        @defaults = defaults
        @report = report
      end

      # Executes the recipe for a single host.
      #
      # @param host [String] host name or identifier.
      # @param params [Hash] runtime parameters merged with defaults.
      # @param context [Hash, Object] mutable context passed into tasks.
      # @param force [Boolean] bypass state store cache.
      # @param options [Hash] additional execution options:
      #   - +:state_store+ [Herd::StateStore::Memory, Herd::StateStore::SQLite]
      #   - +:signature_builder+ [Proc] override signature generation.
      #   - +:concurrency+ [Integer] max parallel tasks.
      #   - +:summary_path+ [String] file path for text report.
      #   - +:json_path+ [String] file path for JSON export.
      # @return [Herd::TaskGraph::RunResult]
      def run(host:, params: {}, context: {}, force: false, **options)
        allowed = %i[state_store signature_builder concurrency summary_path json_path]
        unknown = options.keys - allowed
        raise ArgumentError, "Unknown options: #{unknown.join(", ")}" if unknown.any?

        state_store = options[:state_store]
        signature_builder = options[:signature_builder]
        concurrency = options[:concurrency]
        summary_path = options[:summary_path]
        json_path = options[:json_path]

        graph = Herd::TaskGraph.new(
          report: report,
          state_store: state_store,
          signature_builder: signature_builder
        )

        tasks.each do |task|
          graph.task(task[:name], depends_on: task[:depends_on], **task[:options], &task[:block])
        end

        merged_params = defaults.merge(params)
        result = graph.run(host: host, context: context, params: merged_params, force: force, concurrency: concurrency)
        Herd::ReportWriter.write(report, summary_path: summary_path, json_path: json_path)
        result
      end
    end

    # Internal module used to evaluate recipe files without polluting the main namespace.
    Loader = Module.new do
      extend Herd::DSL
    end

    module_function

    # Builds a recipe in a DSL block.
    #
    # @yieldparam builder [Builder] context used to declare tasks.
    # @return [Recipe]
    def define(&)
      builder = Builder.new
      builder.instance_exec(&)
      builder.build
    end

    # Loads a recipe file using the DSL DSL::Loader context.
    #
    # @param path [String] recipe file path.
    # @return [Recipe]
    def load_file(path)
      recipe = Loader.module_eval(File.read(path), path)
      raise ArgumentError, "Recipe #{path} must return Herd::DSL::Recipe" unless recipe.is_a?(Herd::DSL::Recipe)

      recipe
    end
  end
end
