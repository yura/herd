# frozen_string_literal: true

require "tsort"

module Herd
  # DAG of tasks with dependency-aware execution and reporting.
  class TaskGraph
    Task = Struct.new(:name, :depends_on, :action, keyword_init: true)

    TaskResult = Struct.new(:name, :status, :value, :stdout, :stderr, :error, :skip_reason, keyword_init: true) do
      def success?
        status == :success
      end
    end

    class RunResult
      attr_reader :results

      def initialize(results)
        @results = results
      end

      def [](name)
        results.fetch(name.to_s)
      end

      def success?
        results.values.none? { |result| result.status == :failed }
      end
    end

    def initialize(report: nil)
      @report = report
      @tasks = {}
    end

    def task(name, depends_on: [], &block)
      raise ArgumentError, "block required for task #{name}" unless block

      string_name = name.to_s
      raise ArgumentError, "task #{string_name} already defined" if tasks.key?(string_name)

      dependencies = Array(depends_on).map(&:to_s)
      tasks[string_name] = Task.new(name: string_name, depends_on: dependencies, action: block)
    end

    def run(host:, context: nil)
      validate_dependencies!

      results = {}

      topological_order.each do |task_name|
        task = tasks.fetch(task_name)

        if dependency_unsatisfied?(task, results)
          reason = build_skip_reason(task, results)
          event = start_event(task, host)
          report&.task_skipped(event: event, reason: reason)
          results[task_name] = TaskResult.new(name: task_name, status: :skipped, value: nil, stdout: nil, stderr: nil, error: nil, skip_reason: reason)
          next
        end

        event = start_event(task, host)
        normalized = { value: nil, stdout: nil, stderr: nil }

        begin
          raw_result = task.action.call(context)
          normalized = normalize_result(raw_result)
          report&.task_succeeded(event: event, stdout: normalized[:stdout], stderr: normalized[:stderr])
          results[task_name] = TaskResult.new(
            name: task_name,
            status: :success,
            value: normalized[:value],
            stdout: normalized[:stdout],
            stderr: normalized[:stderr],
            error: nil,
            skip_reason: nil
          )
        rescue StandardError => exception
          report&.task_failed(
            event: event,
            exception: exception,
            stdout: normalized[:stdout],
            stderr: normalized[:stderr]
          )

          results[task_name] = TaskResult.new(
            name: task_name,
            status: :failed,
            value: normalized[:value],
            stdout: normalized[:stdout],
            stderr: normalized[:stderr],
            error: exception,
            skip_reason: nil
          )
        end
      end

      RunResult.new(results)
    end

    private

    attr_reader :report, :tasks

    def validate_dependencies!
      tasks.each_value do |task|
        missing = task.depends_on.reject { |dependency| tasks.key?(dependency) }
        next if missing.empty?

        raise ArgumentError, "undefined dependencies for #{task.name}: #{missing.join(', ')}"
      end
    end

    def topological_order
      dependency_graph.tsort
    end

    def dependency_graph
      graph_tasks = tasks

      Class.new do
        include TSort

        define_method(:initialize) do |nodes|
          @nodes = nodes
        end

        define_method(:tsort_each_node) do |&block|
          @nodes.each_key(&block)
        end

        define_method(:tsort_each_child) do |node, &block|
          @nodes.fetch(node).depends_on.each(&block)
        end
      end.new(graph_tasks)
    end

    def dependency_unsatisfied?(task, results)
      task.depends_on.any? do |dependency|
        dependency_result = results[dependency]
        dependency_result.nil? || dependency_result.status != :success
      end
    end

    def build_skip_reason(task, results)
      failed_dependencies = task.depends_on.filter_map do |dependency|
        dependency_result = results[dependency]
        next unless dependency_result
        next if dependency_result.status == :success

        "#{dependency} #{dependency_result.status}"
      end

      return "dependencies not satisfied" if failed_dependencies.empty?

      "dependencies not satisfied: #{failed_dependencies.join(', ')}"
    end

    def start_event(task, host)
      return unless report

      report.task_started(
        host: host,
        task: task.name,
        command: task.name
      )
    end

    def normalize_result(raw_result)
      case raw_result
      when Herd::ExecutionResult
        {
          value: raw_result.value,
          stdout: raw_result.stdout,
          stderr: raw_result.stderr
        }
      when Hash
        {
          value: raw_result[:value],
          stdout: raw_result[:stdout],
          stderr: raw_result[:stderr]
        }
      when String
        {
          value: raw_result,
          stdout: raw_result,
          stderr: ""
        }
      else
        {
          value: raw_result,
          stdout: nil,
          stderr: nil
        }
      end
    end
  end
end

