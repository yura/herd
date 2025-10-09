# frozen_string_literal: true

require "digest"
require "tsort"

module Herd
  # DAG of tasks with dependency-aware execution, caching, and reporting.
  class TaskGraph
    Task = Struct.new(:name, :depends_on, :action, :options, keyword_init: true)

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

    def initialize(report: nil, state_store: nil, signature_builder: nil)
      @report = report
      @signature_builder = signature_builder || default_signature_builder
      @state_store = state_store.nil? ? Herd.configuration.build_state_store : state_store
      @tasks = {}
    end

    def task(name, depends_on: [], **options, &block)
      raise ArgumentError, "block required for task #{name}" unless block

      string_name = name.to_s
      raise ArgumentError, "task #{string_name} already defined" if tasks.key?(string_name)

      dependencies = Array(depends_on).map(&:to_s)
      tasks[string_name] = Task.new(name: string_name, depends_on: dependencies, action: block, options: options)
    end

    def run(host:, context: nil, params: {}, force: false, concurrency: nil)
      concurrency = resolve_concurrency(concurrency)
      context ||= {}
      validate_dependencies!

      results =
        if concurrency > 1
          run_parallel(host: host, context: context, params: params, force: force, concurrency: concurrency)
        else
          run_sequential(host: host, context: context, params: params, force: force)
        end

      RunResult.new(results)
    end

    private

    attr_reader :report, :state_store, :signature_builder, :tasks

    def resolve_concurrency(value)
      configured = Herd.configuration.concurrency
      resolved = value || configured
      resolved = resolved.to_i if resolved
      resolved&.positive? ? resolved : 1
    end

    def run_sequential(host:, context:, params:, force: false)
      ctx = prepare_context_object(context, host, params)
      results = {}

      topological_order.each do |task_name|
        task = tasks.fetch(task_name)
        results[task_name] = execute_task(task, host, ctx, params, force, results)
      end

      results
    end

    def run_parallel(host:, context:, params:, force:, concurrency:)
      ctx = prepare_context_object(context, host, params)
      results = {}
      processed = []

      ready = tasks.keys.select { |name| tasks[name].depends_on.empty? }

      until ready.empty?
        level_results = process_level(ready, host, ctx, params, force, concurrency, results)
        results.merge!(level_results)
        processed.concat(ready)
        remaining = tasks.keys - processed
        ready = remaining.select do |name|
          tasks[name].depends_on.all? { |dependency| results.key?(dependency) }
        end
      end

      (tasks.keys - processed).each do |name|
        next if results.key?(name)

        task = tasks[name]
        reason = build_skip_reason(task, results)
        event = start_event(task, host)
        report&.task_skipped(event: event, reason: reason)
        results[name] = TaskResult.new(
          name: name,
          status: :skipped,
          value: nil,
          stdout: nil,
          stderr: nil,
          error: nil,
          skip_reason: reason
        )
      end

      results
    end

    def process_level(task_names, host, context, params, force, concurrency, existing_results)
      return {} if task_names.empty?

      work_queue = Queue.new
      task_names.each { |name| work_queue << name }
      worker_count = [concurrency, task_names.size].min
      worker_count.times { work_queue << nil }

      level_results = {}
      mutex = Mutex.new

      workers = worker_count.times.map do
        Thread.new do
          loop do
            name = work_queue.pop
            break unless name

            task = tasks.fetch(name)
            result = execute_task(task, host, context, params, force, existing_results)
            mutex.synchronize { level_results[name] = result }
          end
        end
      end

      workers.each(&:join)
      level_results
    end

    def execute_task(task, host, context, params, force, results_snapshot)
      reason = dependency_skip_reason(task, results_snapshot)
      if reason
        event = start_event(task, host)
        report&.task_skipped(event: event, reason: reason)
        return TaskResult.new(
          name: task.name,
          status: :skipped,
          value: nil,
          stdout: nil,
          stderr: nil,
          error: nil,
          skip_reason: reason
        )
      end

      signature = build_signature(task, params, context)
      if (entry = fetch_cache_entry(task, host, signature, force: force))
        event = start_event(task, host)
        report&.task_skipped(event: event, reason: "cache hit")
        return TaskResult.new(
          name: task.name,
          status: :cached,
          value: entry.value,
          stdout: entry.stdout,
          stderr: entry.stderr,
          error: nil,
          skip_reason: "cache hit"
        )
      end

      event = start_event(task, host)
      normalized = { value: nil, stdout: nil, stderr: nil }

      begin
        raw_result = task.action.call(context)
        normalized = normalize_result(raw_result)
        report&.task_succeeded(event: event, stdout: normalized[:stdout], stderr: normalized[:stderr])
        entry = Herd::StateStore::Entry.new(
          status: :success,
          stdout: normalized[:stdout],
          stderr: normalized[:stderr],
          value: normalized[:value],
          schema_version: schema_version(task)
        )
        write_cache(task, host, signature, entry)

        TaskResult.new(
          name: task.name,
          status: :success,
          value: normalized[:value],
          stdout: normalized[:stdout],
          stderr: normalized[:stderr],
          error: nil,
          skip_reason: nil
        )
      rescue StandardError => e
        report&.task_failed(
          event: event,
          exception: e,
          stdout: normalized[:stdout],
          stderr: normalized[:stderr]
        )

        TaskResult.new(
          name: task.name,
          status: :failed,
          value: normalized[:value],
          stdout: normalized[:stdout],
          stderr: normalized[:stderr],
          error: e,
          skip_reason: nil
        )
      end
    end

    def dependency_skip_reason(task, results_snapshot)
      return nil if task.depends_on.empty?

      return nil unless task.depends_on.any? do |dependency|
        dependency_result = results_snapshot[dependency]
        dependency_result && !successful_status?(dependency_result.status)
      end

      build_skip_reason(task, results_snapshot)
    end

    def prepare_context_object(context, host, params)
      ctx = context || {}
      if ctx.is_a?(Hash)
        ctx[:host] ||= host
        ctx[:params] ||= params
      end
      ctx
    end

    def validate_dependencies!
      tasks.each_value do |task|
        missing = task.depends_on.reject { |dependency| tasks.key?(dependency) }
        next if missing.empty?

        raise ArgumentError, "undefined dependencies for #{task.name}: #{missing.join(", ")}"
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
        dependency_result.nil? || !successful_status?(dependency_result.status)
      end
    end

    def fetch_cache_entry(task, host, signature, force:)
      return nil unless state_store && signature

      state_store.fetch(host: host, task: task.name, signature: signature, force: force)
    end

    def write_cache(task, host, signature, entry)
      return unless state_store && signature

      state_store.write(host: host, task: task.name, signature: signature, entry: entry)
    end

    def schema_version(task)
      task.options[:schema_version] || 1
    end

    def build_signature(task, params, context = nil)
      return unless signature_builder

      signature_params = params.merge(extract_signature_params(task, context, params))
      signature_builder.call(task.name, signature_params)
    end

    def default_signature_builder
      lambda do |task_name, params|
        normalized = params.to_a.sort_by { |(key, _)| key.to_s }
        digest = Digest::SHA256.new
        digest.update(task_name.to_s)
        normalized.each do |key, value|
          digest.update("|#{key}=#{value}")
        end
        digest.hexdigest
      end
    end

    def extract_signature_params(task, context, params)
      raw = task.options[:signature_params]
      case raw
      when Proc
        value = raw.call(context, params)
        value.respond_to?(:to_h) ? value.to_h : {}
      when Hash
        raw
      else
        {}
      end
    end

    def successful_status?(status)
      %i[success cached].include?(status)
    end

    def build_skip_reason(task, results)
      failed_dependencies = task.depends_on.filter_map do |dependency|
        dependency_result = results[dependency]
        next unless dependency_result
        next if successful_status?(dependency_result.status)

        "#{dependency} #{dependency_result.status}"
      end

      return "dependencies not satisfied" if failed_dependencies.empty?

      "dependencies not satisfied: #{failed_dependencies.join(", ")}"
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
