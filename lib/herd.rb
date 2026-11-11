# frozen_string_literal: true

require_relative "herd/version"

module Herd
  # Top line of files Herd writes; defined before commands load, which use it in constants.
  MANAGED_HEADER = "# Managed by Herd. Do not edit manually."

  # Defined before commands load: command modules subclass it.
  class CommandError < StandardError; end

  # Herd can't tell whether the remote command finished: it may have run fully, partly, or
  # still be running (e.g. children of a killed shell). Never retried automatically.
  class CommandOutcomeUnknown < CommandError; end

  # The channel was closed at the deadline; the remote command may still be running.
  class CommandTimeout < CommandOutcomeUnknown; end

  # An SSH option given to Host that rsync's ssh can't be told about.
  class UnsupportedSSHOption < CommandError; end

  # Records a cleanup failure (a temporary file left behind) on the error that was
  # already on its way up, readable as error.cleanup_errors; the original error stays.
  def self.attach_cleanup_error(error, cleanup)
    errors = error.respond_to?(:cleanup_errors) ? error.cleanup_errors : []
    errors << cleanup
    error.define_singleton_method(:cleanup_errors) { errors }
  end
end

require_relative "herd/log"
require_relative "herd/host"
require_relative "herd/inventory"
require_relative "herd/runner"
require_relative "herd/command_result"
require_relative "herd/transport"
require_relative "herd/session"
require_relative "herd/playbook"
require_relative "herd/deployer"
