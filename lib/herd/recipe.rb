# frozen_string_literal: true

module Herd
  # Represents a recipe composed of dependency-aware tasks.
  class Recipe
    Task = Struct.new(:name, :dependencies, :block, keyword_init: true)

    class << self
      # Loads a recipe file and returns a Recipe instance.
      #
      # @param path [String] path to the recipe file.
      # @return [Recipe]
      def load(path)
        builder = Builder.new
        builder.instance_eval(File.read(path), path)
        new(builder.tasks)
      end
    end

    def initialize(tasks)
      @tasks = tasks
    end

    # Executes tasks in dependency order using the provided runner.
    #
    # @param runner [Herd::Runner]
    # @param report [Herd::Report]
    # @return [Herd::Report]
    def run(runner, report: Herd::Report.new, progress: nil)
      total_tasks = sorted_tasks.size * runner.hosts.size
      progress&.reset(total_tasks: total_tasks)

      sorted_tasks.each do |task|
        execute_task(task, runner, report, progress)
      end

      progress&.finish
      report
    end

    private

    attr_reader :tasks

    def sorted_tasks
      @sorted_tasks ||= topologically_sorted_tasks
    end

    def execute_task(task, runner, report, progress)
      progress&.task_started(task.name)
      runner.exec(&task.block).each do |result|
        report.add(task_name: task.name, result: result)
        progress&.task_completed(task.name, result)
      end
    end

    def topologically_sorted_tasks
      tasks_by_name = tasks.to_h { |task| [task.name, task] }
      visited = {}
      order = []

      tasks.each do |task|
        visit_task(task, tasks_by_name, visited, order)
      end

      order
    end

    def visit_task(task, tasks_by_name, visited, order)
      state = visited[task.name]
      raise ArgumentError, "Circular dependency detected for #{task.name}" if state == :visiting
      return if state == :visited

      visited[task.name] = :visiting
      task.dependencies.each do |dependency_name|
        visit_dependency(task, dependency_name, tasks_by_name, visited, order)
      end

      visited[task.name] = :visited
      order << task
    end

    def visit_dependency(task, dependency_name, tasks_by_name, visited, order)
      dependency = tasks_by_name.fetch(dependency_name) do
        raise ArgumentError, "Unknown dependency #{dependency_name} for #{task.name}"
      end

      visit_task(dependency, tasks_by_name, visited, order)
    end

    # Internal builder used to capture task definitions from recipe files.
    class Builder
      attr_reader :tasks

      def initialize
        @tasks = []
        @task_names = {}
      end

      def task(name, depends_on: [], &block)
        raise ArgumentError, "block required for task #{name}" unless block

        task_name = name.to_sym
        raise ArgumentError, "Task #{task_name} already defined" if @task_names.key?(task_name)

        @task_names[task_name] = true
        tasks << Task.new(
          name: task_name,
          dependencies: Array(depends_on).map(&:to_sym),
          block: block
        )
      end
    end
  end
end
