# frozen_string_literal: true

require_relative "herd/version"
require_relative "herd/execution_result"
require_relative "herd/configuration"
require_relative "herd/host"
require_relative "herd/runner"
require_relative "herd/session"
require_relative "herd/run_report"
require_relative "herd/state_store"
require_relative "herd/task_graph"
require_relative "herd/dsl"
require_relative "herd/report_writer"

# Herd orchestrates remote task execution with persistent SSH sessions and
# a dependency-aware task graph.
module Herd
  # Generic error raised when a remote command reports stderr output.
  class CommandError < StandardError; end

  class << self
    # Returns singleton configuration shared across the process.
    #
    # @return [Herd::Configuration]
    def configuration
      @configuration ||= Herd::Configuration.new
    end

    # Convenience helper yielding the global configuration for inline tweaks.
    #
    # @yieldparam config [Herd::Configuration]
    # @return [void]
    def configure
      yield(configuration)
    end
  end
end
