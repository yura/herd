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

module Herd
  class CommandError < StandardError; end

  class << self
    def configuration
      @configuration ||= Herd::Configuration.new
    end

    def configure
      yield(configuration)
    end
  end
end
