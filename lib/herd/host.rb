# frozen_string_literal: true

require "csv"
require "json"
require "net/ssh"

module Herd
  # Target host
  class Host
    include Herd::Log

    attr_reader :host, :port, :user, :ssh_options, :password, :vars, :log

    # port, private_key_path, password are for the ssh connection
    def initialize(host, user, options)
      @host = host
      @user = user

      create_ssh_options(options)

      @port = ssh_options[:port]
      @password = options.delete(:password)
      @vars = options.merge(host: host, user: user, port: ssh_options[:port])

      open_log
    end

    def create_ssh_options(options)
      @ssh_options = { port: options[:port] || 22, timeout: 10 }
      if options[:private_key_path]
        @ssh_options[:keys] = [options.delete(:private_key_path)]
      else
        @ssh_options[:password] = options[:password]
      end
    end

    def exec(command = nil, &)
      Net::SSH.start(host, user, ssh_options) do |ssh|
        session = Herd::Session.new(self, ssh, password, log)

        output = session.send(command) if command
        output = session.instance_exec(vars, &) if block_given?
        output
      end
    rescue StandardError => e
      log_connection_error(e)
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
