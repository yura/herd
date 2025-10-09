# frozen_string_literal: true

require "net/ssh"
require "thread"

module Herd
  # Target host maintaining a persistent SSH session.
  class Host
    attr_reader :host, :user, :ssh_options

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
    end

    # Executes a command or block within a persistent SSH session.
    def exec(command = nil, &block)
      session = ensure_session

      execute_with_session(session, command, &block)
    rescue StandardError
      reset_session
      raise
    end

    # Closes the underlying SSH session explicitly.
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
    def execute_with_session(session, command, &block)
      @exec_mutex.synchronize do
        session.execute(command, &block)
      end
    end

    # Establishes a new SSH connection.
    def connect
      Net::SSH.start(host, user, ssh_options)
    end

    # Closes and clears any cached session.
    def reset_session
      @session_mutex.synchronize do
        @session&.close
        @session = nil
      end
    end
  end
end
