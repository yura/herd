# frozen_string_literal: true

require "shellwords"

module Herd
  # Session for executing commands on the remote host
  class Session
    include Herd::Log
    include Herd::Transport

    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("commands", __dir__)
    DEFAULT_COMMAND_TIMEOUT = 3600
    ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    attr_reader :host, :ssh, :log

    def initialize(host, ssh, password, log)
      @host = host
      @ssh = ssh
      @password = password
      @log = log
    end

    def password
      host&.password || @password
    end

    def exec(command, vars, &)
      output = send(command) if command
      output = instance_exec(vars, &) if block_given?
      output
    end

    def method_missing(cmd, *args)
      command_parts = [cmd.to_s]
      command_parts.concat(args.map(&:to_s)) if args.any?
      command = command_parts.join(" ")

      run(command)
    end

    SUDO_PROMPT = "HERD_SUDO: "
    # sudo prints its default prompt instead of ours when a sudoers rule sets passprompt_override.
    SUDO_DEFAULT_PROMPT = "[sudo] password for "

    # The prefix every sudo call goes through; the prompt is how channel_run knows to send the password.
    def sudo_prefix
      "sudo -p '#{SUDO_PROMPT}'"
    end

    def sudo(command, **)
      run("#{sudo_prefix} #{command}", **, sudo_prompt: true)
    end

    # Marks value as a secret: the log replaces it with "[redacted]" wherever it appears.
    # Commands that carry secrets should still pass sensitive: true — a secret that was
    # shell-escaped or encoded no longer matches. Returns value.
    def secret(value)
      host&.add_secret(value)
      value
    end

    # Values are shell expressions ("...:$PATH" expands), not literals — shellescape those.
    # Nests: the outer env is restored after the block.
    def with_env(env)
      env.each_key do |name|
        raise ArgumentError, "with_env: #{name.inspect} is not a variable name" unless name.to_s.match?(ENV_NAME)
      end
      previous = @env
      @env = (@env || {}).merge(env)
      yield
    ensure
      @env = previous
    end

    # Runs a shell command as written (expansion, globs, pipes are yours) in the
    # current +within+ directory and +with_env+ environment, and logs it.
    #
    # sensitive: true keeps the command, its output and its error out of the log,
    # the exception message and HERD_STREAM.
    #
    # @return [String] stdout
    # @raise [Herd::CommandError] on a nonzero exit status; use {#run_result} or
    #   {#command_success?} when a nonzero status is an expected answer
    def run(command, **opts)
      result = run_result(command, **opts)
      sensitive = opts[:sensitive] || inside_sensitive_upload?
      raise ::Herd::CommandError, command_error_message(result, sensitive: sensitive) unless result.success?

      result.output
    end

    # Just whether the command exited 0, as with {#run_result}.
    #
    #   command_success?("test -e /etc/hosts")
    #
    # @return [Boolean]
    # @raise [Herd::CommandError] for SSH or PTY failures, not for a nonzero exit status
    def command_success?(command, **)
      run_result(command, **).success?
    end

    # Like {#run} — same directory, environment, PTY and logging — but a nonzero
    # exit status is returned instead of raised, for commands where it's an answer:
    #
    #   result = run_result("grep 'pattern' /var/log/myapp.log")
    #   result.exit_code  # 0: matches, 1: no matches, 2: an error
    #
    # pty: false runs without a terminal: stdout and stderr come back separately and
    # byte for byte, but sudo can't prompt for a password. stdin: (pty: false only)
    # is sent to the command's standard input.
    #
    # timeout: covers opening the channel as well as the command, in seconds; nil waits forever.
    # On expiry the channel is closed and CommandTimeout raised — the remote process
    # may still be running, nothing guarantees it was stopped.
    #
    # @return [Herd::CommandResult]
    # @raise [Herd::CommandError] for SSH or PTY failures
    # sudo_prompt: true (what sudo passes) lets the channel answer sudo's password prompt;
    # any other command never gets the password, whatever it prints.
    def run_result(command, pty: true, stdin: nil, sensitive: false, timeout: command_timeout, sudo_prompt: false)
      raise ArgumentError, "stdin: needs pty: false" if stdin && pty

      sensitive ||= inside_sensitive_upload?

      caller_method = caller_locations.find { |loc| !loc.path.include?("/lib/herd/") }&.label

      channel_run(remote_script(command), pty: pty, stdin: stdin, sensitive: sensitive, timeout: timeout,
                                          caller_method: caller_method, sudo_prompt: sudo_prompt)
    end

    # True once a command in this session ended with an unknown outcome (timeout, killed
    # shell), even if the caller rescued it: something may still be running on the host.
    def outcome_unknown? = @outcome_unknown == true

    # Nests: the outer directory is restored after the block. path is a path, so "~/app"
    # means the SSH user's home and spaces stay literal.
    def within(path)
      previous = @working_dir
      @working_dir = path
      yield
    ensure
      @working_dir = previous
    end

    def respond_to_missing?(cmd, include_private = false)
      OS_COMMANDS.include?(cmd) || super
    end

    class << self
      def load_command_modules
        command_files.each { |file| require file }

        command_modules.each do |mod|
          next if self <= mod

          prepend mod
        end
      end

      private

      def command_files
        Dir[File.join(CUSTOM_COMMANDS_DIR, "*.rb")]
      end

      def command_modules
        return [] unless defined?(Herd::Commands)

        Herd::Commands.constants
                      .sort
                      .map { |const_name| Herd::Commands.const_get(const_name) }
                      .grep(Module)
      end
    end

    private

    # The script a command runs as: +with_env+ exports and the +within+ directory on lines of
    # their own, each ending the script when it fails, then the command as written. A failed
    # cd can't be skipped by the command's own ";", newlines or comments, as with "cd && cmd".
    def remote_script(command)
      setup = (@env || {}).map { |k, v| "export #{k}=#{v}" }
      setup << "cd #{shell_path(@working_dir)}" if @working_dir
      return command if setup.empty?

      # Added here to every setup line, so none can be left without it.
      [*setup.map { |line| "#{line} || exit 1" }, command].join("\n")
    end

    # host.vars[:command_timeout], else HERD_COMMAND_TIMEOUT, else an hour.
    def command_timeout
      value = host&.vars&.fetch(:command_timeout, nil) || ENV.fetch("HERD_COMMAND_TIMEOUT", nil)
      value ? Float(value) : DEFAULT_COMMAND_TIMEOUT
    end

    def command_error_message(result, sensitive: false)
      return ["[redacted]", result.exit_code].to_s if sensitive

      [result.stdout + result.stderr, result.exit_code].to_s
    end

    # State of one command's channel, filled in by the net-ssh callbacks.
    ChannelState = Struct.new(:stdout, :stderr, :pending, :skip_feedback, :prompts_answered,
                              :exit_code, :closed, :error) do
      def initialize = super("".b, "".b, "".b, false, 0, nil, false, nil)
    end

    def channel_run(command, pty:, stdin:, sensitive:, timeout:, caller_method:, sudo_prompt: false)
      started_at = Time.now
      log_command_start(started_at, command, caller_method, sensitive: sensitive, input: stdin)

      command_result = ssh_execute(command, pty: pty, stdin: stdin, sensitive: sensitive, timeout: timeout,
                                            sudo_prompt: sudo_prompt)
      log_result(command, command_result, started_at, caller_method, sensitive: sensitive)
      command_result
    end

    # The SSH boundary: runs the fully composed command (directory, env and quoting already
    # applied) under "set -o pipefail" in a new channel and collects the result. Specs that
    # run commands with the local bash replace only this method.
    def ssh_execute(command, pty:, stdin:, sensitive:, timeout:, sudo_prompt: false)
      deadline = timeout && (monotonic_now + timeout)
      state    = ChannelState.new
      answers  = pty && sudo_prompt
      channel  = ssh.open_channel do |ch|
        if pty
          ch.request_pty do |c, success|
            raise ::Herd::CommandError, "could not obtain pty" unless success

            channel_exec(c, command, state, stdin, answers, sensitive)
          end
        else
          channel_exec(ch, command, state, stdin, answers, sensitive)
        end
      end
      channel.on_open_failed { |_, code, reason| state.error = "could not open channel: #{reason} (#{code})" }
      channel.on_close { |_| state.closed = true }

      wait_for_channel(channel, state, deadline, timeout)
      raise ::Herd::CommandError, state.error if state.error

      # No exit status: the remote shell was killed (exit-signal) or the channel dropped. What
      # the command did, and whether its children still run, is unknown.
      if state.exit_code.nil?
        @outcome_unknown = true
        raise ::Herd::CommandOutcomeUnknown, "channel closed without exit status"
      end

      flush_pending(state, sensitive)
      Herd::CommandResult.new(stdout: state.stdout.force_encoding(Encoding::UTF_8),
                              stderr: state.stderr.force_encoding(Encoding::UTF_8),
                              exit_code: state.exit_code)
    end

    def channel_exec(channel, command, state, stdin, answers, sensitive)
      channel.exec("set -o pipefail; #{command}") do |c, success|
        unless success
          state.error = "could not execute command"
          next
        end

        c.on_data { |_, data| on_stdout(c, data.b, state, answers, sensitive) }
        c.on_extended_data { |_, _, data| state.stderr << data.b }
        c.on_request("exit-status") { |_, data| state.exit_code = data.read_long }

        if stdin
          c.send_data(stdin.b)
          c.eof!
        end
      end
    end

    # Waits for the channel to close. With a deadline the loop wakes every 0.1s to check it.
    def wait_for_channel(channel, state, deadline, timeout)
      ssh.loop(deadline && 0.1) do
        next false if state.closed || state.error

        if deadline && monotonic_now > deadline
          channel.close
          # close only queues the packet; without a flush it waits for the next command's loop.
          ssh.process(0)
          @outcome_unknown = true
          raise ::Herd::CommandTimeout,
                "command timed out after #{timeout}s — the remote command may still be running"
        end
        true
      end
    end

    # A sudo prompt can arrive split across chunks, so the tail that could still be the
    # start of one is held back until the next chunk shows whether it is.
    def on_stdout(channel, data, state, answers, sensitive)
      if state.skip_feedback
        # After the password sudo echoes nothing, or "*" per char with pwfeedback, then a newline.
        newline = data.index("\n") or return
        state.skip_feedback = false
        data = data[(newline + 1)..]
      end
      return emit_stdout(data, state, sensitive) unless answers

      buffer = state.pending + data
      state.pending = "".b
      prompt_at, prompt_end = sudo_prompt_in(buffer)

      if prompt_at
        emit_stdout(buffer[0...prompt_at], state, sensitive)
        answer_sudo_prompt(channel, state)
        on_stdout(channel, buffer[prompt_end..], state, answers, sensitive) unless buffer[prompt_end..].empty?
      else
        keep = prompt_prefix_length(buffer)
        emit_stdout(buffer[0...(buffer.bytesize - keep)], state, sensitive)
        state.pending = buffer[(buffer.bytesize - keep)..]
      end
    end

    # [start, end] byte offsets of a sudo prompt in buffer, or nil. The default prompt
    # ends with the user name and ": ", so it only counts once that ": " has arrived.
    def sudo_prompt_in(buffer)
      if (at = buffer.index(SUDO_PROMPT.b))
        return [at, at + SUDO_PROMPT.bytesize]
      end

      at = buffer.index(SUDO_DEFAULT_PROMPT.b) or return
      colon = buffer.index(": ", at + SUDO_DEFAULT_PROMPT.bytesize) or return
      [at, colon + 2]
    end

    # Length of the longest tail of buffer that a sudo prompt could start with.
    def prompt_prefix_length(buffer)
      at = buffer.rindex(SUDO_DEFAULT_PROMPT.b)
      return buffer.bytesize - at if at

      [SUDO_PROMPT.b, SUDO_DEFAULT_PROMPT.b].map do |prompt|
        (1...prompt.bytesize).reverse_each.find { |n| buffer.end_with?(prompt[0, n]) } || 0
      end.max
    end

    # A second prompt means sudo rejected the password; answering again would only lock the account sooner.
    def answer_sudo_prompt(channel, state)
      if state.prompts_answered.positive?
        state.error = "sudo: authentication failed"
        channel.close
        return
      end

      state.prompts_answered += 1
      channel.send_data("#{password}\n")
      state.skip_feedback = true
    end

    def emit_stdout(data, state, sensitive)
      return if data.empty?

      state.stdout << data
      # strip ANSI escape codes produced by PTY before printing
      return unless ENV["HERD_STREAM"] && !sensitive

      print data.dup.force_encoding(Encoding::UTF_8).scrub.gsub(/\e\[[0-9;]*[A-Za-z]|\e./,
                                                                "")
    end

    def flush_pending(state, sensitive)
      emit_stdout(state.pending, state, sensitive)
      state.pending = "".b
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log_result(command, result, started_at, caller_method, sensitive:)
      if result.success?
        log_command_output(command, result, started_at, caller_method, sensitive: sensitive)
      else
        log_command_error(command, result, started_at, caller_method, sensitive: sensitive)
      end
    end
  end
end

Herd::Session.load_command_modules
