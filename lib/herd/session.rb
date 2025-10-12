# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    COMMANDS = %i[cat chmod echo hostname touch].freeze

    attr_reader :ssh

    def initialize(ssh)
      @ssh = ssh
    end

    def authorized_keys
      cat("~/.ssh/authorized_keys")&.chomp&.split("\n") || []
    end

    def add_authorized_key(key)
      touch("~/.ssh/authorized_keys")
      chmod("600 ~/.ssh/authorized_keys")
      echo "'#{key}' >> ~/.ssh/authorized_keys"
    end

    def method_missing(cmd, *args)
      command_parts = [cmd.to_s]
      command_parts.concat(args.map(&:to_s)) if args.any?
      command = command_parts.join(" ")

      ssh.exec! command do |_, stream, data|
        raise ::Herd::CommandError, data if stream == :stderr

        return data
      end
    end

    def respond_to_missing?(cmd)
      COMMANDS.include?(cmd) || super
    end
  end
end
