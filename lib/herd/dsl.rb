# frozen_string_literal: true

module Herd
  module DSL
    # Builder collects task declarations for a recipe.
    class Builder
      attr_reader :tasks, :report

      def initialize
        @tasks = []
        @defaults = {}
        @report = Herd::RunReport.new
      end

      def defaults(values = nil)
        return @defaults.dup if values.nil?

        @defaults.merge!(values)
      end

      def task(name, depends_on: [], **options, &block)
        raise ArgumentError, "block required for task #{name}" unless block

        tasks << {
          name: name.to_s,
          depends_on: Array(depends_on).map(&:to_s),
          options: options,
          block: block
        }
      end

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

    Loader = Module.new do
      extend Herd::DSL
    end

    module_function

    def define(&)
      builder = Builder.new
      builder.instance_exec(&)
      builder.build
    end

    def load_file(path)
      recipe = Loader.module_eval(File.read(path), path)
      raise ArgumentError, "Recipe #{path} must return Herd::DSL::Recipe" unless recipe.is_a?(Herd::DSL::Recipe)

      recipe
    end
  end
end
