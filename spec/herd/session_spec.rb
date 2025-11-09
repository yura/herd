# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Session do
  let(:session) { described_class.new(mock_ssh_session, "T0pS3kr3t", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil) }

  before do
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)

    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:exec).with("hostname").and_yield(mock_ssh_channel, nil)
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "alpha001")
    allow(mock_ssh_channel).to receive(:on_extended_data)
  end

  describe "#method_missing" do
    before do
      allow(mock_ssh_session).to receive(:exec!).with("hostname").and_yield(nil, :stdout, "alpha001")
    end

    it "delegates calls to SSH session" do
      session.hostname
      expect(mock_ssh_channel).to have_received(:exec).with("hostname")
    end

    it "returns command output" do
      expect(session.hostname).to eq("alpha001")
    end
  end

  context "with AuthorizedKeys commands" do
    it "preprends authorized keys helpers" do
      expect(described_class.ancestors).to include(Herd::Commands::AuthorizedKeys)
    end

    describe "#authorized_keys" do
      before do
        allow(mock_ssh_channel).to receive(:exec).with("cat ~/.ssh/authorized_keys")
                                                 .and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "key1\nkey2\n")
      end

      it "returns list of remote authorized keys" do
        expect(session.authorized_keys).to eq(%w[key1 key2])
      end
    end

    describe "#add_authorized_key" do
      let(:public_key) { "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC" }

      before do
        allow(mock_ssh_channel).to receive(:exec).with("touch ~/.ssh/authorized_keys")
                                                 .and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to receive(:exec).with("sudo chmod 600 ~/.ssh/authorized_keys")
                                                 .and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to receive(:exec).with("tee -a ~/.ssh/authorized_keys << EOF\n#{public_key}\nEOF")
                                                 .and_yield(mock_ssh_channel, nil)
      end

      it "touches the authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_channel).to have_received(:exec).with("touch ~/.ssh/authorized_keys")
      end

      it "sets strict permissions on authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_channel).to have_received(:exec).with("sudo chmod 600 ~/.ssh/authorized_keys")
      end

      it "appends the key into authorized keys file" do
        session.add_authorized_key(public_key)
        command = "tee -a ~/.ssh/authorized_keys << EOF\n#{public_key}\nEOF"
        expect(mock_ssh_channel).to have_received(:exec).with(command)
      end
    end
  end

  context "with Packages commands" do
    it "preprends packages helpers" do
      expect(described_class.ancestors).to include(Herd::Commands::Packages)
    end

    describe "#install_packages" do
      let(:command) { %(echo -e 'T0pS3kr3t\n' | sudo -S apt install -qq -y openssh-server) }

      before do
        allow(mock_ssh_channel).to receive(:exec).with(command).and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "Done\n")
      end

      it "ssh channel receives the command" do
        session.install_packages("openssh-server")

        expect(mock_ssh_channel).to have_received(:exec).with(command)
      end

      it "installs packages" do
        session.install_packages("openssh-server")

        expect(mock_ssh_channel).to have_received(:on_data)
      end
    end
  end
end
