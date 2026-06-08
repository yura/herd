# frozen_string_literal: true

require "csv"
require "json"
require "net/ssh"
require "net/ssh/proxy/jump"

module Herd
  # Target host
  class Host
    include Herd::Log

    attr_reader :host, :port, :user, :ssh_options, :vars, :log, :password

    # port, private_key_path, password are for the ssh connection
    def initialize(host, options = {})
      @host = host

      compose_ssh_options(options)

      @vars = options.merge(host: host, user: user, port: ssh_options[:port])
    end

    def compose_ssh_options(options)
      ssh_config = Net::SSH::Config.for(host)

      @password = options.delete(:password)
      @identity_file = options.delete(:identity_file)

      @ssh_options = { password: @password, port: 22, timeout: 10 }.merge(ssh_config).merge(options)
      @user = ssh_options[:user]
      @port = ssh_options[:port]

      @ssh_options[:keys] = [@identity_file] if @identity_file
    end

    def password=(value)
      @password = value
      @ssh_options[:password] = value
    end

    def method_missing(name, *args)
      vars.key?(name) ? vars[name] : super
    end

    def respond_to_missing?(name, include_private = false)
      vars.key?(name) || super
    end

    def exec(command = nil, &)
      open_log
      Net::SSH.start(host, user, ssh_options) do |ssh|
        Herd::Session.new(self, ssh, password, log).exec(command, vars, &)
      end
    rescue Herd::CommandError
      raise
    rescue Net::SSH::ConnectionTimeout, Errno::ETIMEDOUT
      raise Herd::CommandError, "cannot connect to #{user}@#{host}:#{port} — connection timed out"
    rescue Errno::ECONNREFUSED
      raise Herd::CommandError, "cannot connect to #{user}@#{host}:#{port} — connection refused"
    rescue Net::SSH::AuthenticationFailed
      raise Herd::CommandError, "cannot connect to #{user}@#{host}:#{port} — authentication failed"
    rescue StandardError => e
      log_connection_error(e)
      raise
    ensure
      close_log
    end

    def self.from_csv(file = "hosts.csv")
      CSV.read(file, headers: true).map do |csv|
        h = csv.to_h.transform_keys(&:to_sym)
        host = h.delete(:host)
        user = h.delete(:user)
        port = h.delete(:port).to_i
        new(host, h.merge(user: user, port: port))
      end
    end
  end
end
