# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    COMMANDS = %i[cat chmod echo hostname touch].freeze
    COMMANDS_DIR = File.expand_path("session/commands", __dir__)

    attr_reader :ssh

    def initialize(ssh)
      @ssh = ssh
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

    class << self
      def load_command_modules
        command_files.each { |file| require file }

        session_command_modules.each do |mod|
          next if ancestors.include?(mod)

          prepend mod
        end
      end

      private

      def command_files
        Dir[File.join(COMMANDS_DIR, "*.rb")]
      end

      def session_command_modules
        return [] unless defined?(Herd::SessionCommands)

        Herd::SessionCommands.constants
                             .sort
                             .map { |const_name| Herd::SessionCommands.const_get(const_name) }
                             .select { |value| value.is_a?(Module) }
      end
    end
  end
end

Herd::Session.load_command_modules
