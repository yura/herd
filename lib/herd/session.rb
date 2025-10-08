# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    COMMANDS = %i[hostname].freeze

    attr_reader :ssh

    def initialize(ssh)
      @ssh = ssh
    end

    def method_missing(cmd, *args)
      command = cmd.to_s
      command += args.join(" ") if args

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
