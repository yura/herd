# frozen_string_literal: true

require "csv"
require "json"
require "net/ssh"
require "net/ssh/proxy/jump"

module Herd
  # Target host
  class Host
    include Herd::Log

    attr_reader :host, :port, :user, :ssh_options, :vars, :log, :proxy_jump, :password

    def password=(value)
      @password = value
      @ssh_options[:password] = value
    end

    # port, private_key_path, password are for the ssh connection
    def initialize(host, user, options)
      @host = host
      @user = user

      create_ssh_options(options)

      @port = ssh_options[:port]
      @password = options.delete(:password)
      @vars = options.merge(host: @host, user: user, port: ssh_options[:port])
    end

    def create_ssh_options(options)
      cfg = Net::SSH::Config.for(@host)

      @host = cfg.delete(:host_name) if cfg[:host_name]

      @ssh_options = { port: 22, timeout: 10 }.merge(cfg)
      @ssh_options[:port] = options[:port] if options[:port]


      if options[:private_key_path]
        @ssh_options[:keys] = [options.delete(:private_key_path)]
      elsif options[:password]
        @ssh_options[:password] = options[:password]
      end

      if options[:proxy_jump]
        @proxy_jump = options[:proxy_jump]
        @ssh_options[:proxy] = Net::SSH::Proxy::Jump.new(@proxy_jump)
      elsif (proxy = @ssh_options[:proxy]).is_a?(Net::SSH::Proxy::Jump)
        @proxy_jump = proxy.instance_variable_get(:@proxy_jump)
      end

      @ssh_options[:verify_host_key] = options[:verify_host_key] if options[:verify_host_key]
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
        new(host, user, h.merge(port: port))
      end
    end
  end
end
