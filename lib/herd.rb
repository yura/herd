# frozen_string_literal: true

require_relative "herd/version"
require_relative "herd/host"
require_relative "herd/execution_result"
require_relative "herd/report"
require_relative "herd/progress_reporter"
require_relative "herd/runner"
require_relative "herd/recipe"
require_relative "herd/session"

module Herd
  # Error raised when remote command returns non-zero exit.
  class CommandError < StandardError
    attr_reader :command, :stderr

    def initialize(command, stderr)
      @command = command
      @stderr = stderr
      super("Command '#{command}' failed: #{stderr}")
    end
  end
end
