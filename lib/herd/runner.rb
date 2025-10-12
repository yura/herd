# frozen_string_literal: true

module Herd
  # Runner for running commands on all hosts simultaneously
  class Runner
    attr_reader :hosts

    def initialize(hosts)
      @hosts = hosts
    end

    def exec(command = nil, &)
      threads = hosts.map do |host|
        Thread.new { host.exec(command, &) }
      end

      threads.each(&:join)
      threads.map(&:value)
    end
  end
end
