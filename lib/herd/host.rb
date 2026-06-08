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

    # ssh_options are ssh configuration options such as port, password, etc.
    # vars are additional named values passed while host configuration such as hostname: "alpha" 
    def initialize(host, ssh_options = {}, vars = {})
      @host = host
      ssh_options = ssh_options.dup
      vars = vars.dup

      if vars.empty? && !(ssh_options.keys - Net::SSH::VALID_OPTIONS).empty?
        vars = (ssh_options.keys - Net::SSH::VALID_OPTIONS).to_h { |k| [k, ssh_options[k]] }
        ssh_options = (ssh_options.keys & Net::SSH::VALID_OPTIONS).to_h { |k| [k, ssh_options[k]] }
      end

      compose_ssh_options(ssh_options)

      @vars = vars.merge(host: host, user: user, port: port)
    end

    def compose_ssh_options(opts)
      cfg = Net::SSH::Config.for(host)

      @password = opts.delete(:password)

      @ssh_options = { password: @password, port: 22, timeout: 10 }.merge(cfg).merge(opts)
      @user = ssh_options[:user]
      @port = ssh_options[:port]
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
