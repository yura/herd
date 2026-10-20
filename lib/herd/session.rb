# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    include Herd::Log

    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("commands", __dir__)

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

    def sudo(command)
      run("sudo -p '#{SUDO_PROMPT}' #{command}")
    end

    # Values are shell expressions ("...:$PATH" expands), not literals — shellescape those.
    # Nests: the outer env is restored after the block.
    def with_env(env)
      previous = @env
      @env = (@env || {}).merge(env)
      yield
    ensure
      @env = previous
    end

    # Runs a shell command as written (expansion, globs, pipes are yours) in the
    # current +within+ directory and +with_env+ environment, and logs it.
    #
    # @return [String] output collected from the PTY
    # @raise [Herd::CommandError] on a nonzero exit status; use {#run_result} or
    #   {#command_success?} when a nonzero status is an expected answer
    def run(command)
      result = run_result(command)
      raise ::Herd::CommandError, [result.output, result.exit_code] unless result.success?

      result.output
    end

    # Just whether the command exited 0, as with {#run_result}.
    #
    #   command_success?("test -e /etc/hosts")
    #
    # @return [Boolean]
    # @raise [Herd::CommandError] for SSH or PTY failures, not for a nonzero exit status
    def command_success?(command)
      run_result(command).success?
    end

    # Like {#run} — same directory, environment, PTY and logging — but a nonzero
    # exit status is returned instead of raised, for commands where it's an answer:
    #
    #   result = run_result("grep 'pattern' /var/log/myapp.log")
    #   result.exit_code  # 0: matches, 1: no matches, 2: an error
    #
    # @return [Herd::CommandResult]
    # @raise [Herd::CommandError] for SSH or PTY failures
    def run_result(command)
      caller_method = caller_locations.find { |loc| !loc.path.include?("/lib/herd/") }&.label
      env_exports   = @env&.map { |k, v| "export #{k}=#{v}" }&.join("; ")
      full_command  = @working_dir ? "cd #{@working_dir} && #{command}" : command
      full_command  = "#{env_exports}; #{full_command}" if env_exports
      result = []
      ssh.open_channel do |channel|
        channel.request_pty do |ch, success|
          raise ::Herd::CommandError, "could not obtain pty" unless success

          channel_run(ch, full_command, result, Time.now, caller_method)
        end
      end
      ssh.loop
      result.fetch(0)
    end

    # Nests: the outer directory is restored after the block.
    def within(path)
      previous = @working_dir
      @working_dir = path
      yield
    ensure
      @working_dir = previous
    end

    def respond_to_missing?(cmd)
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

    def channel_run(channel, command, result, started_at, caller_method = nil)
      log_command_start(started_at, command, caller_method)

      raw_bytes = "".b
      exit_code = nil
      stderr_output = nil
      channel.exec("set -o pipefail; #{command}") do |c, _|
        c.on_data do |_, data|
          data_utf8 = data.dup.force_encoding("UTF-8")
          if data_utf8.include?(SUDO_PROMPT) || data_utf8.include?("[sudo] password for")
            c.send_data "#{password}\n"
          else
            # strip ANSI escape codes produced by PTY before printing
            print data.gsub(/\e\[[0-9;]*[A-Za-z]|\e./, "") if ENV["HERD_STREAM"]
            raw_bytes << data.b
          end
        end
        c.on_extended_data { |_, _, data| stderr_output = data }
        c.on_request("exit-status") { |_, data| exit_code = data.read_long }
      end

      ssh.loop { exit_code.nil? }
      output = stderr_output || raw_bytes.dup.force_encoding("UTF-8")

      command_result = Herd::CommandResult.new(output: output, exit_code: exit_code)
      log_result(command, command_result, started_at, caller_method)
      result << command_result
    end

    def log_result(command, result, started_at, caller_method)
      if result.success?
        log_command_output(command, result.output, started_at, caller_method)
      else
        log_command_error(command, result.output, started_at, result.exit_code, caller_method)
      end
    end
  end
end

Herd::Session.load_command_modules
