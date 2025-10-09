# frozen_string_literal: true

module Herd
  # Runner for running commands on all hosts simultaneously.
  class Runner
    attr_reader :hosts

    def initialize(hosts)
      @hosts = hosts
    end

    # Executes the command (or block) on every host, optionally reporting progress.
    def exec(command = nil, task: nil, report: nil, &block)
      task_block = block

      threads = hosts.map do |host|
        Thread.new { run_for_host(host, command, task: task, report: report, block: task_block) }
      end

      threads.each(&:join)
      threads.map(&:value)
    end

    private

    # Runs the command for a single host and pipes lifecycle events to the report.
    def run_for_host(host, command, task:, report:, block: nil)
      event = start_event(report, host, task, command)

      result = host.exec(command, &block)
      report&.task_succeeded(event: event, stdout: result, stderr: nil) if event
      result
    rescue StandardError => e
      if report
        report.task_failed(event: event || start_event(report, host, task, command), exception: e, stdout: nil, stderr: nil)
      end
      raise
    end

    # Creates and returns the reporting event for a host if a report exists.
    def start_event(report, host, task, command)
      return unless report

      report.task_started(
        host: host_identifier(host),
        task: task || command,
        command: command
      )
    end

    # Extracts a host identifier for reporting purposes.
    def host_identifier(host)
      host.respond_to?(:host) ? host.host : host.to_s
    end
  end
end
