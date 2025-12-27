# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    include Herd::Log

    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("commands", __dir__)

    attr_reader :host, :ssh, :password, :log

    def initialize(host, ssh, password, log)
      @host = host
      @ssh = ssh
      @password = password
      @log = log
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

      output, exit_code = nil
      channel.exec("set -o pipefail; #{command}") do |c, _|
        c.on_data { |_, data| output = data }
        c.on_extended_data { |_, _, data| output = data }
        c.on_request("exit-status") { |_, data| exit_code = data.read_long }
      end

      ssh.loop { exit_code.nil? }

      output_with_code = { output: output, exit_code: exit_code }
      process_output(channel, command, started_at, output_with_code, result)
    end

    def process_output(channel, command, started_at, output_with_code, result)
      output = output_with_code[:output]
      exit_code = output_with_code[:exit_code]
      if exit_code.zero?
        process_success(channel, command, started_at, output, result)
      else
        process_error(command, started_at, output, exit_code)
      end
    end

    def process_success(channel, command, started_at, data, result)
      if data&.include?("[sudo] password for")
        channel.send_data "#{password}\n"
      else
        log_command_output(command, data, started_at)
        result << data
      end
    end

    def process_error(command, started_at, data, exit_code)
      log_command_error(command, data, started_at, exit_code)
      raise ::Herd::CommandError, [data, exit_code]
    end
  end
end

Herd::Session.load_command_modules
