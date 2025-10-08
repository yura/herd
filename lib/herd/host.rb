# frozen_string_literal: true

require "net/ssh"

module Herd
  # Target host
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
    end

    def exec(command = nil, &block)
      Net::SSH.start(host, user, ssh_options) do |ssh|
        session = Herd::Session.new(ssh)

        output = nil
        output = session.send(command) if command
        output = session.instance_exec(&block) if block_given?
        output
      end
    end
  end
end
