# frozen_string_literal: true

require "net/ssh"

module Herd
  # Target host
  class Host
    attr_reader :host, :user, :ssh_options, :alias_name

    def initialize(host, user, **options)
      @host = host
      @user = user
      @alias_name = options[:alias_name]
      @ssh_options = build_ssh_options(options)
    end

    def exec(command = nil, &block)
      started_at = Time.now
      session_holder = { session: nil }
      value, exception = execute_with_capture(session_holder, command, block)
      ResultBuilder.call(self, session_holder[:session], value, exception, started_at)
    end

    private

    def build_ssh_options(options)
      ssh_options = {
        port: options.fetch(:port, 22),
        timeout: options.fetch(:timeout, 10)
      }

      if options[:private_key_path]
        ssh_options[:keys] = [options[:private_key_path]]
      elsif options.key?(:password)
        ssh_options[:password] = options[:password]
      end

      ssh_options
    end

    def execute_with_capture(session_holder, command, block)
      value = nil
      exception = nil

      begin
        value = run_in_session(session_holder, command, block)
      rescue StandardError => e
        exception = e
      end

      [value, exception]
    end

    def run_in_session(session_holder, command, block)
      Net::SSH.start(host, user, ssh_options) do |ssh|
        session_holder[:session] = Herd::Session.new(ssh).tap { |session| session.attach_host(self) }
        execute_command(session_holder[:session], command, block)
      end
    end

    def execute_command(session, command, block)
      return session.send(command) if command
      return session.instance_exec(&block) if block

      nil
    end

    # Builds execution results for host operations.
    class ResultBuilder
      def self.call(host, session, value, exception, started_at)
        stdout_log, stderr_log, commands = session_logs(session)
        finished_at = Time.now
        attributes = base_attributes(host, value, commands, exception)
                     .merge(stream_attributes(stdout_log, stderr_log))
                     .merge(timing_attributes(started_at, finished_at))

        Herd::ExecutionResult.new(attributes)
      end

      def self.session_logs(session)
        return ["", "", []] unless session

        [session.stdout_log, session.stderr_log, session.transcript]
      end

      def self.base_attributes(host, value, commands, exception)
        { host: host, value: value, commands: commands, exception: exception }
      end

      def self.stream_attributes(stdout_log, stderr_log)
        { stdout: stdout_log, stderr: stderr_log }
      end

      def self.timing_attributes(started_at, finished_at)
        { started_at: started_at, finished_at: finished_at, duration: finished_at - started_at }
      end
    end

    public

    def identity
      return alias_name if alias_name && !alias_name.empty?

      base = user ? "#{user}@" : ""
      port = ssh_options[:port]
      "#{base}#{host}:#{port}"
    end
  end
end
