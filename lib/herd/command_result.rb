# frozen_string_literal: true

module Herd
  # What {Session#run_result} returns. With a PTY (the default) the remote stderr arrives
  # mixed into stdout and stderr stays empty; with pty: false they are separate.
  CommandResult = Data.define(:stdout, :stderr, :exit_code) do
    # output: is the pre-stdout name, kept for callers that build results themselves.
    def initialize(exit_code:, stdout: nil, stderr: "", output: nil)
      super(stdout: stdout || output || "", stderr: stderr, exit_code: exit_code)
    end

    def output = stdout

    def success?
      exit_code.zero?
    end
  end
end
