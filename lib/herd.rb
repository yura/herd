# frozen_string_literal: true

require_relative "herd/version"

module Herd
  # Top line of files Herd writes; defined before commands load, which use it in constants.
  MANAGED_HEADER = "# Managed by Herd. Do not edit manually."
end

require_relative "herd/log"
require_relative "herd/host"
require_relative "herd/inventory"
require_relative "herd/runner"
require_relative "herd/session"
require_relative "herd/playbook"
require_relative "herd/deployer"

module Herd
  class CommandError < StandardError; end
end
