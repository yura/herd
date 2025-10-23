# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("session/commands", __dir__)

    attr_reader :ssh, :password

    def initialize(ssh, password = nil)
      @ssh = ssh
      @password = password
    end

    def method_missing(cmd, *args)
      command_parts = [cmd.to_s]
      command_parts.concat(args.map(&:to_s)) if args.any?
      command = command_parts.join(" ")

      run(command)
    end

    def run(command)
      result = []
      ssh.open_channel do |channel|
        channel.request_pty do |ch, success|
          raise ::Herd::CommandError, "could not obtain pty" unless success

          channel_run(ch, command, result)
        end
      end
      ssh.loop
      result.join
    end

    def respond_to_missing?(cmd)
      OS_COMMANDS.include?(cmd) || super
    end

    class << self
      def load_command_modules
        command_files.each { |file| require file }

        session_command_modules.each do |mod|
          next if self <= mod

          prepend mod
        end
      end

      private

      def command_files
        Dir[File.join(CUSTOM_COMMANDS_DIR, "*.rb")]
      end

      def session_command_modules
        return [] unless defined?(Herd::SessionCommands)

        Herd::SessionCommands.constants
                             .sort
                             .map { |const_name| Herd::SessionCommands.const_get(const_name) }
                             .select { |value| value.is_a?(Module) }
      end
    end

    private

    def channel_run(channel, command, result)
      channel.exec(command) do |c, _|
        c.on_data do |_, data|
          if data.include?("[sudo] password for")
            c.send_data "#{password}\n"
          else
            result << data
          end
        end

        c.on_extended_data { |_, _, data| raise ::Herd::CommandError, data }
      end
    end
  end
end

Herd::Session.load_command_modules
