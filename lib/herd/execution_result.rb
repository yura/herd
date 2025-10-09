# frozen_string_literal: true

module Herd
  # Captures the outcome of a command executed on a host.
  ExecutionResult = Struct.new(:value, :stdout, :stderr, keyword_init: true)
end
