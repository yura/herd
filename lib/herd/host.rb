require "net/ssh"

class Herd::Host
  attr_reader :host
  attr_reader :port
  attr_reader :user
  attr_reader :private_key_path
  attr_reader :password

  def initialize(host, user, port: 22, private_key_path: nil, password: nil)
    @host = host
    @user = user
    @port = port
    @private_key_path = private_key_path
    @password = password
  end

  def hostname
    ssh "hostname"
  end

  def ssh_options
    options = { port: port, timeout: 10 }
    if private_key_path
      options[:keys] = [ private_key_path ]
    else
      options[:password] = password
    end
    options
  end

  def ssh(command)
    output = nil

    Net::SSH.start(host, user, ssh_options) do |ssh|
      ssh.exec! command do |ch, stream, data|
        if stream == :stderr
          raise CommandError.new(data)
        else
          output = data 
        end
      end     
    end
    
    output
  end
end


