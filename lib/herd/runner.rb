# frozen_string_literal: true

module Herd
  # Runner for running commands on all hosts simultaneously
  class Runner
    attr_reader :hosts

    def initialize(hosts)
      @hosts = hosts
    end

    def exec(command = nil, &)
      if hosts.empty?
        puts "runner: no hosts to run against — nothing to run"
        return []
      end

      threads = hosts.map do |host|
        Thread.new { host.exec(command, &) }
      end

      threads.each do |t|
        t.join
      rescue StandardError
        nil
      end

      errors  = []
      results = threads.map do |t|
        t.value
      rescue StandardError => e
        errors << e
        nil
      end

      raise errors.first if errors.one?
      raise Herd::CommandError, errors.map(&:message).join("; ") if errors.any?

      results
    end
  end
end
