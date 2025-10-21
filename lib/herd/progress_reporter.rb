# frozen_string_literal: true

module Herd
  # Streams task execution progress for hosts using ANSI terminal output.
  class ProgressReporter
    STATUS_SYMBOL = {
      running: "…",
      success: "✔",
      failed: "✖",
      idle: "•"
    }.freeze

    def initialize(hosts:, recipe:, output: $stdout)
      @recipe = recipe
      @output = output
      @states = {}.compare_by_identity
      hosts.each { |host| @states[host] = initial_state(host) }
      @total_tasks = 0
      @completed_tasks = 0
      @display = Display.new(output, recipe)
    end

    def reset(total_tasks:)
      @total_tasks = total_tasks
      render
    end

    def task_started(task_name)
      @states.each_value do |state|
        state[:current_task] = task_name.to_s
        state[:status] = :running unless state[:status] == :failed
      end
      render
    end

    def task_completed(task_name, result)
      state = @states[result.host]
      return unless state

      state[:status] = result.success? ? :success : :failed
      state[:last_error] = result.exception&.message
      state[:current_task] = result.success? ? nil : task_name.to_s

      @completed_tasks += 1

      render
    end

    def finish
      @states.each_value { |state| state[:current_task] = nil }
      render
    end

    private

    attr_reader :display

    def initial_state(host)
      {
        host: host,
        current_task: nil,
        status: :idle,
        last_error: nil
      }
    end

    def render
      display.render(@states.values, @completed_tasks, @total_tasks)
    end

    # Handles ANSI aware rendering.
    class Display
      STATUS_COLORS = {
        running: "\e[33m",
        success: "\e[32m",
        failed: "\e[31m",
        idle: "\e[36m"
      }.freeze

      def initialize(output, recipe)
        @output = output
        @recipe = recipe
      end

      def render(states, completed_tasks, total_tasks)
        return unless output

        clear_output if ansi_supported?

        lines = [header_line(completed_tasks, total_tasks)]
        lines.concat(states.map { |state| format_line(state, completed_tasks, total_tasks) })

        output.puts(lines.join("\n"))
        output.flush
      end

      private

      attr_reader :output, :recipe

      def header_line(done, total)
        format("Progress: %<done>d/%<total>d tasks completed", done: done, total: total)
      end

      def format_line(state, completed, total)
        segments = line_segments(state, completed, total)
        colored(segments.join(" "), state[:status])
      end

      def host_label(host)
        return host.alias_name if host.respond_to?(:alias_name) && host.alias_name && !host.alias_name.empty?

        if host.respond_to?(:user) && host.respond_to?(:host) && host.respond_to?(:ssh_options)
          port = host.ssh_options[:port]
          "#{host.user}@#{host.host}:#{port}"
        else
          host.to_s
        end
      end

      def line_segments(state, completed, total)
        status = state[:status]
        segments = base_segments(state, completed, total)
        error_segment = failure_message(status, state[:last_error])
        error_segment ? segments + [error_segment] : segments
      end

      def base_segments(state, completed, total)
        [
          STATUS_SYMBOL[state[:status]],
          host_label(state[:host]),
          "[#{recipe}]",
          "[#{state[:current_task] || "idle"}]",
          format("[total: %<done>d/%<total>d]", done: completed, total: total)
        ]
      end

      def failure_message(status, last_error)
        return unless status == :failed && last_error

        last_error
      end

      def colored(text, status)
        return text unless ansi_supported?

        color = STATUS_COLORS[status] || STATUS_COLORS[:idle]
        "#{color}#{text}\e[0m"
      end

      def clear_output
        output.print("\e[2J\e[H")
      end

      def ansi_supported?
        output.respond_to?(:tty?) && output.tty?
      end
    end
  end
end
