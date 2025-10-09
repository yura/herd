# frozen_string_literal: true

require "thread"

module Herd
  # Collects lifecycle data for task execution runs.
  class RunReport
    def initialize(clock: -> { Time.now })
      @clock = clock
      @events = []
      @mutex = Mutex.new
    end

    # Returns a snapshot of current events.
    def events
      synchronize { @events.map(&:dup) }
    end

    # Records that a task started running with the provided context.
    def task_started(**context)
      event = default_event.merge(context)

      synchronize { @events << event }
      event
    end

    # Marks the task as succeeded and stores output streams.
    def task_succeeded(event:, stdout:, stderr:)
      finalize_event(event, status: :success, stdout: stdout, stderr: stderr, exception: nil)
    end

    # Marks the task as failed and captures exception metadata.
    def task_failed(event:, exception:, stdout:, stderr:)
      exception_payload = {
        class: exception.class.name,
        message: exception.message,
        backtrace: exception.backtrace
      }

      finalize_event(event, status: :failed, stdout: stdout, stderr: stderr, exception: exception_payload)
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
        exception: nil
      }
    end

    # Updates the task event with completion data.
    def finalize_event(event, status:, stdout:, stderr:, exception:)
      finished_at = current_time

      synchronize do
        event[:status] = status
        event[:stdout] = stdout
        event[:stderr] = stderr
        event[:finished_at] = finished_at
        event[:duration] = finished_at - event[:started_at]
        event[:exception] = exception
      end

      event
    end

    # Returns the current time via the injected clock.
    def current_time
      clock.call
    end

    # Serializes access to the shared event store.
    def synchronize(&block)
      @mutex.synchronize(&block)
    end
  end
end
