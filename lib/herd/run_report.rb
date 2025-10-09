# frozen_string_literal: true

require "json"
require "time"

module Herd
  # Collects lifecycle data for task execution runs.
  class RunReport
    # @param clock [#call] monotonic time provider returning current time.
    def initialize(clock: -> { Time.now })
      @clock = clock
      @events = []
      @mutex = Mutex.new
    end

    # Returns a snapshot of current events.
    # Returns a defensive copy of the tracked events.
    #
    # @return [Array<Hash>]
    def events
      synchronize { @events.map(&:dup) }
    end

    # Records that a task started running with the provided context.
    #
    # @param context [Hash] event metadata.
    # @return [Hash] live event instance.
    def task_started(**context)
      event = default_event.merge(context)

      synchronize { @events << event }
      event
    end

    # Marks the task as succeeded and stores output streams.
    #
    # @param event [Hash] event returned by {#task_started}.
    # @param stdout [String, nil]
    # @param stderr [String, nil]
    # @return [Hash] updated event.
    def task_succeeded(event:, stdout:, stderr:)
      finalize_event(event, status: :success, stdout: stdout, stderr: stderr, exception: nil, skip_reason: nil)
    end

    # Marks the task as failed and captures exception metadata.
    #
    # @param event [Hash]
    # @param exception [Exception]
    # @param stdout [String, nil]
    # @param stderr [String, nil]
    # @return [Hash] updated event.
    def task_failed(event:, exception:, stdout:, stderr:)
      exception_payload = {
        class: exception.class.name,
        message: exception.message,
        backtrace: exception.backtrace
      }

      finalize_event(event, status: :failed, stdout: stdout, stderr: stderr, exception: exception_payload,
                            skip_reason: nil)
    end

    # Marks the task as skipped with an optional reason.
    #
    # @param event [Hash]
    # @param reason [String, nil]
    # @return [Hash] updated event.
    def task_skipped(event:, reason: nil)
      finalize_event(event, status: :skipped, stdout: nil, stderr: nil, exception: nil, skip_reason: reason)
    end

    # Human readable summary string for the collected events.
    #
    # @return [String]
    def summary
      counts = aggregate_counts
      lines = []
      lines << format(
        "Tasks: %<total>d total | success: %<success>d | failed: %<failed>d | running: %<running>d | skipped: %<skipped>d",
        counts
      )

      if counts[:total].positive?
        total = total_duration
        lines << format("Total runtime: %.3fs", total || 0.0)
      end

      ordered_events.each do |event|
        lines << format_event_line(event)
      end

      lines.join("\n")
    end

    # Hash representation of the report useful for exporting.
    #
    # @return [Hash]
    def to_h
      counts = aggregate_counts

      {
        totals: counts,
        duration: total_duration,
        events: ordered_events.map { |event| serialize_event(event) }
      }
    end

    # JSON export of the report.
    #
    # @return [String]
    def to_json(*)
      to_h.to_json(*)
    end

    private

    attr_reader :clock

    # Builds the initial structure for a task event.
    def default_event
      {
        status: :running,
        started_at: current_time,
        finished_at: nil,
        duration: nil,
        stdout: nil,
        stderr: nil,
        exception: nil,
        skip_reason: nil
      }
    end

    # Updates the task event with completion data.
    def finalize_event(event, status:, stdout:, stderr:, exception:, skip_reason:)
      finished_at = current_time

      synchronize do
        event[:status] = status
        event[:stdout] = stdout
        event[:stderr] = stderr
        event[:finished_at] = finished_at
        event[:duration] = finished_at - event[:started_at]
        event[:exception] = exception
        event[:skip_reason] = skip_reason
      end

      event
    end

    # Returns the current time via the injected clock.
    def current_time
      clock.call
    end

    # Serializes access to the shared event store.
    def synchronize(&)
      @mutex.synchronize(&)
    end

    def aggregate_counts
      counts = Hash.new(0)

      events.each do |event|
        counts[event[:status]] += 1
      end

      counts[:success] ||= 0
      counts[:failed] ||= 0
      counts[:running] ||= 0
      counts[:skipped] ||= 0
      counts[:total] = events.count

      counts
    end

    def total_duration
      starts = events.filter_map { |event| event[:started_at] }
      finishes = events.filter_map { |event| event[:finished_at] }

      return nil if starts.empty? || finishes.empty?

      finishes.max - starts.min
    end

    def ordered_events
      events.sort_by { |event| event[:started_at] || Time.at(0) }
    end

    def format_event_line(event)
      duration = event[:duration] ? format("%.3fs", event[:duration]) : "-"
      line = format(
        " - %<task>s@%<host>s [%<status>s] (%<duration>s)",
        task: event[:task],
        host: event[:host],
        status: event[:status],
        duration: duration
      )

      if event[:exception]
        line += format(
          " %<class>s: %<message>s",
          class: event[:exception][:class],
          message: event[:exception][:message]
        )
      elsif event[:status] == :skipped && event[:skip_reason]
        line += format(" reason: %s", event[:skip_reason])
      end

      line
    end

    def serialize_event(event)
      event.transform_keys(&:to_s).merge(
        "started_at" => serialize_time(event[:started_at]),
        "finished_at" => serialize_time(event[:finished_at]),
        "duration" => event[:duration]
      )
    end

    def serialize_time(value)
      value&.iso8601
    end
  end
end
