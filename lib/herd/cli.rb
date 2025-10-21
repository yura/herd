# frozen_string_literal: true

require "optparse"

require "herd/cli/run_command"

module Herd
  # Minimal command-line interface for running recipes on multiple hosts.
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      return usage unless argv.first == "run"

      argv.shift
      RunCommand.new(argv).execute
    rescue StandardError => e
      warn e.message
      1
    end

    private

    attr_reader :argv

    def usage
      warn "Usage: herd run <recipe.rb> --hosts=hosts.csv"
      1
    end
  end
end
