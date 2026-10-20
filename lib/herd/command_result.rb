# frozen_string_literal: true

module Herd
  # What {Session#run_result} returns: output collected from the remote PTY
  # and the command's exit status.
  CommandResult = Data.define(:output, :exit_code) do
    def success?
      exit_code.zero?
    end
  end
end
