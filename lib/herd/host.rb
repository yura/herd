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

      resolve_ssh_alias!(options) unless options[:port]

      create_ssh_options(options)

      @port = ssh_options[:port]
      @password = options.delete(:password)
      @vars = options.merge(host: @host, user: user, port: ssh_options[:port])
    end

    def create_ssh_options(options)
      @ssh_options = { port: options[:port] || 22, timeout: 10 }
      if options[:private_key_path]
        @ssh_options[:keys] = [options.delete(:private_key_path)]
      else
        @ssh_options[:password] = options[:password]
      end
      if options[:proxy_jump]
        @proxy_jump = options[:proxy_jump]
        @ssh_options[:proxy] = Net::SSH::Proxy::Jump.new(@proxy_jump)
      end
      @ssh_options[:verify_host_key] = options[:verify_host_key] if options[:verify_host_key]
    end

    def resolve_ssh_alias!(options)
      output = `ssh -G #{@host} 2>/dev/null`
      return unless $?.success?

      parsed = output.lines.each_with_object({}) do |line, h|
        k, v = line.strip.split(" ", 2)
        h[k] = v
      end

      @host          = parsed["hostname"] if parsed["hostname"]
      options[:port] = parsed["port"].to_i if parsed["port"]

      jump = parsed["proxyjump"]
      options[:proxy_jump] = jump if jump && jump != "none"

      options[:verify_host_key] = :never if %w[no false].include?(parsed["stricthostkeychecking"]&.downcase)
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
