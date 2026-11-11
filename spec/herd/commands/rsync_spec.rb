# frozen_string_literal: true

require "net/ssh/proxy/jump"

RSpec.describe Herd::Commands::Files, "#rsync_communication_program" do
  def ssh_command(**options)
    host = Herd::Host.new("10.0.0.1", { user: "deploy", password: "x", timeout: 5 }.merge(options))
    Herd::Session.new(host, nil, nil, StringIO.new).rsync_communication_program
  end

  it "translates the options given to Host into ssh arguments" do
    command = ssh_command(port: 2222, keys: ["/keys/id ed25519"], keys_only: true,
                          proxy: Net::SSH::Proxy::Jump.new("bastion"), user_known_hosts_file: ["/k/hosts"],
                          host_key_alias: "web", verify_host_key: :never)

    expect(command).to eq("ssh -o BatchMode=yes -p 2222 -i '/keys/id ed25519' -o IdentitiesOnly=yes -J bastion " \
                          "-o UserKnownHostsFile=/k/hosts -o HostKeyAlias=web -o StrictHostKeyChecking=no")
  end

  it "leaves options that don't change the connection, and ~/.ssh/config, to ssh itself" do
    expect(ssh_command).to eq("ssh -o BatchMode=yes")
  end

  it "refuses an explicit option ssh can't be given, rather than connecting differently" do
    [{ auth_methods: ["publickey"] }, { key_data: ["-----BEGIN"] }, { encryption: "aes256-ctr" }].each do |option|
      expect { ssh_command(**option) }.to raise_error(Herd::UnsupportedSSHOption)
    end
  end
end
