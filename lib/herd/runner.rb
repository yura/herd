# frozen_string_literal: true

module Herd
  # Runner for running commands on all hosts simultaneously
  class Runner
    attr_reader :hosts

    def initialize(hosts)
      @hosts = hosts
    end

    # Runs on every host in parallel. Returns the results in host order; one failed
    # host re-raises its own error, several raise a CommandError joining their messages.
    def exec(command = nil, &)
      results = exec_results(command, &)
      errors  = results.filter_map(&:last)

      raise errors.first if errors.one?
      raise Herd::CommandError, errors.map(&:message).join("; ") if errors.any?

      results.map { |_, value, _| value }
    end

    # Like exec, but never raises: returns [host, value, error] per host, in host order.
    # error is whatever Host#exec raised, a failed connection included.
    def exec_results(command = nil, &)
      if hosts.empty?
        puts "runner: no hosts to run against — nothing to run"
        return []
      end

      threads = hosts.map do |host|
        Thread.new do
          [host, host.exec(command, &), nil]
        rescue StandardError => e
          [host, nil, e]
        end
      end
      threads.map(&:value)
    end
  end
end
