# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("session/commands", __dir__)

    attr_reader :ssh, :current_host

    def initialize(ssh)
      @ssh = ssh
      reset_transcript
    end

    def method_missing(cmd, *args)
      command = build_command(cmd, args)
      stdout, stderr = execute(command)

      record_command(command, stdout, stderr)
      raise ::Herd::CommandError.new(command, stderr) unless stderr.empty?

      stdout
    end

    def respond_to_missing?(cmd)
      OS_COMMANDS.include?(cmd) || super
    end

    def stdout_log
      @stdout_buffer.dup
    end

    def stderr_log
      @stderr_buffer.dup
    end

    def transcript
      @command_log.map(&:dup)
    end

    def attach_host(host)
      @current_host = host
    end

    def host_identity
      current_host&.identity
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

    def build_command(cmd, args)
      ([cmd.to_s] + args.map(&:to_s)).join(" ")
    end

    def execute(command)
      stdout = +""
      stderr = +""

      ssh.exec!(command) do |_, stream, data|
        case stream
        when :stderr then stderr << data
        else stdout << data
        end
      end

      [stdout, stderr]
    end

    def record_command(command, stdout, stderr)
      @command_log << {
        command: command,
        stdout: stdout.dup,
        stderr: stderr.dup
      }

      @stdout_buffer << stdout
      @stderr_buffer << stderr
    end

    def reset_transcript
      @command_log = []
      @stdout_buffer = +""
      @stderr_buffer = +""
    end
  end
end

Herd::Session.load_command_modules
