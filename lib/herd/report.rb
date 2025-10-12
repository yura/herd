# frozen_string_literal: true

require "time"

module Herd
  # Aggregates task execution events for reporting.
  class Report
    attr_reader :mutex

    def initialize
      @events = []
      @mutex = Mutex.new
    end

    def add(task_name:, result:)
      event = build_event(task_name, result)
      synchronize { @events << event }
      event
    end

    def events
      synchronize { @events.map(&:dup) }
    end

    def success?
      events.all? { |event| event[:status] == :success }
    end

    def summary
      snapshot = events
      ([summary_header(snapshot)] + snapshot.map { |event| format_event(event) }).join("\n")
    end

    private

    def host_label(host)
      return host.to_s unless host.respond_to?(:host)
      return host.alias_name if alias?(host)

      base = host.respond_to?(:user) && host.user ? "#{host.user}@" : ""
      base += host.host.to_s
      port = host.respond_to?(:ssh_options) ? host.ssh_options[:port] : nil
      port ? "#{base}:#{port}" : base
    end

    def serialize_exception(exception)
      return nil unless exception

      {
        class: exception.class.name,
        message: exception.message,
        backtrace: exception.backtrace
      }
    end

    def aggregate_counts(events)
      counts = Hash.new(0)

      events.each do |event|
        counts[event[:status]] += 1
      end

      counts[:success] ||= 0
      counts[:failed] ||= 0
      counts[:total] = events.size

      counts
    end

    def summary_header(events)
      counts = aggregate_counts(events)
      format(
        "Tasks: %<total>d total | success: %<success>d | failed: %<failed>d",
        counts
      )
    end

    def format_event(event)
      segments = [
        " - #{event[:host]}",
        "[#{event[:task]}]",
        "[#{event[:status]}]",
        format_duration(event[:duration])
      ]

      append_error(segments, event[:exception]) if event[:status] == :failed
      segments.join(" ")
    end

    def build_event(task_name, result)
      core_event(task_name, result).merge(streams_from(result)).merge(timings_from(result))
    end

    def core_event(task_name, result)
      {
        task: task_name.to_s,
        host: host_label(result.host),
        status: result.success? ? :success : :failed,
        commands: result.commands,
        exception: serialize_exception(result.exception)
      }
    end

    def streams_from(result)
      { stdout: result.stdout, stderr: result.stderr }
    end

    def timings_from(result)
      { started_at: result.started_at, finished_at: result.finished_at, duration: result.duration }
    end

    def format_duration(duration)
      duration ? format("(%.3fs)", duration) : "(-)"
    end

    def append_error(segments, exception)
      return unless exception

      segments << format("%<class>s: %<message>s", class: exception[:class], message: exception[:message])
    end

    def alias?(host)
      host.respond_to?(:alias_name) && host.alias_name && !host.alias_name.empty?
    end

    def synchronize(&)
      mutex.synchronize(&)
    end
  end
end
