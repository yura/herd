# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    include Herd::Log

    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("commands", __dir__)

    attr_reader :ssh, :password, :log

    def initialize(ssh, password, log)
      @ssh = ssh
      @password = password
      @log = log
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

          channel_run(ch, command, result, Time.now)
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
                      .select { |value| value.is_a?(Module) }
      end
    end

    private

    def channel_run(channel, command, result, started_at)
      log_command_start(started_at, command)

      channel.exec(command) do |c, _|
        c.on_data do |_, data|
          process_output(c, command, started_at, data, result)
        end

        c.on_extended_data do |_, _, data|
          process_error(command, started_at, data)
        end
      end
    end

    def process_output(channel, command, started_at, data, result)
      if data.include?("[sudo] password for")
        channel.send_data "#{password}\n"
      else
        log_command_output(command, data, started_at)
        result << data
      end
    end

    def process_error(command, started_at, data)
      log_command_error(command, data, started_at)
      raise ::Herd::CommandError, data
    end
  end
end

Herd::Session.load_command_modules
