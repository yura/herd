# frozen_string_literal: true

require_relative "herd/version"
require_relative "herd/host"
require_relative "herd/runner"
require_relative "herd/session"

module Herd
  class CommandError < StandardError; end
end
