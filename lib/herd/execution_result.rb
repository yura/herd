# frozen_string_literal: true

module Herd
  # Captures the outcome of executing a recipe task on a host.
  ExecutionResult = Struct.new(
    :host,
    :value,
    :stdout,
    :stderr,
    :commands,
    :exception,
    :started_at,
    :finished_at,
    :duration,
    keyword_init: true
  ) do
    def success?
      exception.nil?
    end
  end
end
