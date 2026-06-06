# frozen_string_literal: true

module Herd
  # Session for executing commands on the remote host
  class Session
    include Herd::Log

    OS_COMMANDS = %i[cat chmod echo hostname touch].freeze
    CUSTOM_COMMANDS_DIR = File.expand_path("commands", __dir__)

    attr_reader :host, :ssh, :log

    def initialize(host, ssh, password, log)
      @host = host
      @ssh = ssh
      @password = password
      @log = log
    end

    def password
      host&.password || @password
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

    def with_env(env)
      @env = (@env || {}).merge(env)
      yield
    ensure
      @env = nil
    end

    def run(command)
      caller_method = caller_locations.find { |loc| !loc.path.include?("/lib/herd/") }&.label
      env_exports   = @env&.map { |k, v| "export #{k}=#{v}" }&.join("; ")
      full_command  = @working_dir ? "cd #{@working_dir} && #{command}" : command
      full_command  = "#{env_exports}; #{full_command}" if env_exports
      result = []
      ssh.open_channel do |channel|
        channel.request_pty do |ch, success|
          raise ::Herd::CommandError, "could not obtain pty" unless success

          channel_run(ch, full_command, result, Time.now, caller_method)
        end
      end
      ssh.loop
      result.join
    end

    def within(path)
      @working_dir = path
      yield
    ensure
      @working_dir = nil
    end

    def info(message)
      label = host.vars[:hostname] || host.host
      puts "[#{label}] #{message}"
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
                      .grep(Module)
      end
    end

    private

    def channel_run(channel, command, result, started_at, caller_method = nil)
      log_command_start(started_at, command, caller_method)

      output, exit_code = nil
      channel.exec("set -o pipefail; #{command}") do |c, _|
        c.on_data do |_, data|
          data_utf8 = data.dup.force_encoding("UTF-8")
          if data_utf8.include?("[sudo] password for") || data_utf8.include?("[sudo] пароль для")
            c.send_data "#{password}\n"
          else
            # strip ANSI escape codes produced by PTY before printing
            print data.gsub(/\e\[[0-9;]*[A-Za-z]|\e./, "") if ENV["HERD_STREAM"]
            output = output.to_s + data.encode("UTF-8", "BINARY", invalid: :replace, undef: :replace)
          end
        end
        c.on_extended_data { |_, _, data| output = data }
        c.on_request("exit-status") { |_, data| exit_code = data.read_long }
      end

      ssh.loop { exit_code.nil? }

      output_with_code = { output: output, exit_code: exit_code }
      process_output(channel, command, started_at, output_with_code, result, caller_method)
    end

    def process_output(channel, command, started_at, output_with_code, result, caller_method = nil)
      output = output_with_code[:output]
      exit_code = output_with_code[:exit_code]
      if exit_code.zero?
        process_success(channel, command, started_at, output, result, caller_method)
      else
        process_error(command, started_at, output, exit_code, caller_method)
      end
    end

    def process_success(_channel, command, started_at, data, result, caller_method = nil)
      log_command_output(command, data, started_at, caller_method)
      result << data
    end

    def process_error(command, started_at, data, exit_code, caller_method = nil)
      log_command_error(command, data, started_at, exit_code, caller_method)
      raise ::Herd::CommandError, [data, exit_code]
    end
  end
end

Herd::Session.load_command_modules
