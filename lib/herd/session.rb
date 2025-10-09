# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host.
  class Session
    # Remote helpers exposed as Ruby methods inside {#execute}.
    COMMANDS = %i[hostname].freeze

    attr_reader :ssh, :last_result

    # @param ssh [Net::SSH::Connection::Session] open SSH connection.
    def initialize(ssh)
      @ssh = ssh
      reset_buffers
      @last_result = nil
    end

    # Runs a direct command or evaluates a block within the session.
    #
    # @param command [String, nil] literal command to execute.
    # @yield DSL block evaluated with SSH helpers.
    # @return [Herd::ExecutionResult]
    def execute(command = nil, &)
      reset_buffers
      value = nil

      begin
        value = run(command) if command
        value = instance_exec(&) if block_given?
        store_result(value)
      rescue StandardError => e
        store_result(value)
        raise e
      end

      last_result
    end

    # Closes the underlying SSH connection.
    #
    # @return [void]
    def close
      ssh.close unless closed?
    end

    # Indicates whether the SSH connection has been closed.
    #
    # @return [Boolean]
    def closed?
      ssh.closed?
    end

    # Dispatches unknown methods to remote commands (e.g., +hostname+).
    #
    # @param cmd [Symbol]
    # @param args [Array]
    # @return [String] command output.
    def method_missing(cmd, *args)
      run(build_command(cmd, args))
    end

    # @return [Boolean]
    def respond_to_missing?(cmd)
      COMMANDS.include?(cmd) || super
    end

    private

    attr_reader :stdout_buffer, :stderr_buffer

    def run(command)
      stdout = +""
      stderr = +""

      result = ssh.exec!(command) do |_, stream, data|
        case stream
        when :stdout
          stdout << data
        when :stderr
          stderr << data
        end
      end

      stdout = result if stdout.empty? && result

      append_to_buffers(stdout, stderr)

      raise ::Herd::CommandError, stderr unless stderr.empty?

      stdout
    end

    def build_command(cmd, args)
      parts = [cmd.to_s]
      parts.concat(args.map(&:to_s)) if args.any?
      parts.join(" ")
    end

    def append_to_buffers(stdout, stderr)
      @stdout_buffer << stdout.to_s
      @stderr_buffer << stderr.to_s
    end

    def reset_buffers
      @stdout_buffer = +""
      @stderr_buffer = +""
    end

    def store_result(value)
      @last_result = Herd::ExecutionResult.new(value: value, stdout: stdout_buffer.dup, stderr: stderr_buffer.dup)
    end
  end
end
