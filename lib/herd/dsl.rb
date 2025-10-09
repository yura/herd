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

      def run(host:, params: {}, context: {}, force: false, state_store: nil, signature_builder: nil, concurrency: nil)
        graph = Herd::TaskGraph.new(
          report: report,
          state_store: state_store,
          signature_builder: signature_builder
        )

        tasks.each do |task|
          graph.task(task[:name], depends_on: task[:depends_on], **task[:options], &task[:block])
        end

        merged_params = defaults.merge(params)
        graph.run(host: host, context: context, params: merged_params, force: force, concurrency: concurrency)
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
