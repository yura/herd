# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host.
  class Session
    COMMANDS = %i[hostname].freeze

    attr_reader :ssh

    def initialize(ssh)
      @ssh = ssh
    end

    # Runs a direct command or evaluates a block within the session.
    def execute(command = nil, &block)
      output = nil
      output = public_send(command) if command
      output = instance_exec(&block) if block_given?
      output
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
      command = cmd.to_s
      command += args.join(" ") if args.any?

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

      raise ::Herd::CommandError, stderr unless stderr.empty?

      stdout
    end

    def respond_to_missing?(cmd)
      COMMANDS.include?(cmd) || super
    end
  end
end
