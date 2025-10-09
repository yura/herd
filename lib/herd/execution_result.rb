# frozen_string_literal: true

# Captures the outcome of a command executed on a host.
module Herd
  # Represents the outcome of a task/command execution.
  #
  # @!attribute value
  #   @return [Object] arbitrary payload returned by the task block.
  # @!attribute stdout
  #   @return [String, nil] captured standard output.
  # @!attribute stderr
  #   @return [String, nil] captured standard error.
  ExecutionResult = Struct.new(:value, :stdout, :stderr, keyword_init: true)
end
