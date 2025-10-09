# frozen_string_literal: true

require "net/ssh"

module Herd
  # Target host maintaining a persistent SSH session.
  class Host
    attr_reader :host, :user, :ssh_options, :last_execution

    # @param host [String] remote hostname or IP.
    # @param user [String] SSH username.
    # @param port [Integer] SSH port.
    # @param private_key_path [String, nil] path to SSH private key.
    # @param password [String, nil] password fallback when no key is provided.
    def initialize(host, user, port: 22, private_key_path: nil, password: nil)
      @host = host
      @user = user

      @ssh_options = { port: port, timeout: 10 }
      if private_key_path
        @ssh_options[:keys] = [private_key_path]
      else
        @ssh_options[:password] = password
      end

      @session_mutex = Mutex.new
      @exec_mutex = Mutex.new
      @session = nil
      @last_execution = nil
    end

    # Executes a command or block within a persistent SSH session.
    #
    # @param command [String, nil]
    # @yield remote block executed via {Session#execute}.
    # @return [Object] command return value.
    def exec(command = nil, &)
      session = ensure_session

      execute_with_session(session, command, &)
    rescue StandardError => e
      @last_execution = session.last_result
      reset_session(clear_last: false)
      raise e
    end

    # Closes the underlying SSH session explicitly.
    #
    # @return [void]
    def close
      reset_session
    end

    private

    # Ensures an open session is available for execution.
    def ensure_session
      @session_mutex.synchronize do
        @session = Herd::Session.new(connect) unless session_alive?
        @session
      end
    end

    # Checks if there is an active session cached.
    def session_alive?
      @session && !@session.closed?
    end

    # Executes the command while serializing access per host.
    def execute_with_session(session, command, &)
      @exec_mutex.synchronize do
        result = session.execute(command, &)
        @last_execution = result
        result.value
      end
    end

    # Establishes a new SSH connection.
    def connect
      Net::SSH.start(host, user, ssh_options)
    end

    # Closes and clears any cached session.
    def reset_session(clear_last: true)
      @session_mutex.synchronize do
        @session&.close
        @session = nil
        @last_execution = nil if clear_last
      end
    end
  end
end
