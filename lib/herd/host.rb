# frozen_string_literal: true

require "net/ssh"

module Herd
  # Target host
  class Host
    attr_reader :host, :user, :ssh_options, :password, :vars

    # port, private_key_path, password are for the ssh connection
    def initialize(host, user, options)
      @host = host
      @user = user

      @ssh_options = { port: options.delete(:port) || 22, timeout: 10 }
      if options[:private_key_path]
        @ssh_options[:keys] = [options.delete(:private_key_path)]
      else
        @ssh_options[:password] = options[:password]
      end

      @password = options.delete(:password)
      @vars = options
    end

    def exec(command = nil, &)
      Net::SSH.start(host, user, ssh_options) do |ssh|
        session = Herd::Session.new(ssh, password)

        output = nil
        output = session.send(command) if command
        output = session.instance_exec(vars, &) if block_given?

        output
      end
    end
  end
end
