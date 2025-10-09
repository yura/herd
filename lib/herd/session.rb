# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host.
  class Session
    COMMANDS = %i[hostname].freeze

    attr_reader :ssh, :last_result

    def initialize(ssh)
      @ssh = ssh
      reset_buffers
      @last_result = nil
    end

    # Runs a direct command or evaluates a block within the session.
    def execute(command = nil, &block)
      reset_buffers
      value = nil

      begin
        value = run(command) if command
        value = instance_exec(&block) if block_given?
        store_result(value)
      rescue StandardError => e
        store_result(value)
        raise e
      end

      last_result
    end

    # Closes the underlying SSH connection.
    def close
      ssh.close unless closed?
    end

    # Indicates whether the SSH connection has been closed.
    def closed?
      ssh.closed?
    end

    def method_missing(cmd, *args)
      run(build_command(cmd, args))
    end

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
