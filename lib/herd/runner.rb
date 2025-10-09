# frozen_string_literal: true

module Herd
  # Runner for running commands on all hosts simultaneously.
  class Runner
    attr_reader :hosts

    # @param hosts [Array<#exec>] collection of host-like objects.
    def initialize(hosts)
      @hosts = hosts
    end

    # Executes the command (or block) on every host, optionally reporting progress.
    #
    # @param command [String, nil] command executed remotely.
    # @param task [String, Symbol, nil] logical task name for reporting.
    # @param report [Herd::RunReport, nil] optional report for lifecycle events.
    # @yield remote block executed on each host when +command+ is nil.
    # @return [Array<Object>] per-host return values.
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
      execution = host.last_execution
      if event
        report&.task_succeeded(event: event, stdout: execution_stdout(execution),
                               stderr: execution_stderr(execution))
      end
      result
    rescue StandardError => e
      execution = host.last_execution
      report&.task_failed(
        event: event || start_event(report, host, task, command),
        exception: e,
        stdout: execution_stdout(execution),
        stderr: execution_stderr(execution)
      )
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

    # Extracts stdout for reporting.
    def execution_stdout(execution)
      execution&.stdout
    end

    # Extracts stderr for reporting.
    def execution_stderr(execution)
      execution&.stderr
    end
  end
end
