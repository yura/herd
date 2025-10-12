# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Session do
  let(:session) { described_class.new(mock_ssh_session) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }

  describe "#method_missing" do
    before do
      allow(mock_ssh_session).to receive(:exec!).with("hostname").and_yield(nil, :stdout, "alpha001")
    end

    it "delegates calls to SSH session" do
      session.hostname
      expect(mock_ssh_session).to have_received(:exec!).with("hostname")
    end

    it "returns command output" do
      expect(session.hostname).to eq("alpha001")
    end
  end

  describe "command modules" do
    it "preprends authorized keys helpers" do
      expect(described_class.ancestors).to include(Herd::SessionCommands::AuthorizedKeys)
    end

    describe "#authorized_keys" do
      before do
        allow(mock_ssh_session).to receive(:exec!).with("cat ~/.ssh/authorized_keys")
                                                  .and_yield(nil, :stdout, "key1\nkey2\n")
      end

      it "returns list of remote authorized keys" do
        expect(session.authorized_keys).to eq(%w[key1 key2])
      end
    end

    describe "#add_authorized_key" do
      let(:public_key) { "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC" }

      before do
        allow(mock_ssh_session).to receive(:exec!).with("touch ~/.ssh/authorized_keys")
                                                  .and_yield(nil, :stdout, "")
        allow(mock_ssh_session).to receive(:exec!).with("chmod 600 ~/.ssh/authorized_keys")
                                                  .and_yield(nil, :stdout, "")
        allow(mock_ssh_session).to receive(:exec!).with("echo '#{public_key}' >> ~/.ssh/authorized_keys")
                                                  .and_yield(nil, :stdout, "")
      end

      it "touches the authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_session).to have_received(:exec!).with("touch ~/.ssh/authorized_keys")
      end

      it "sets strict permissions on authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_session).to have_received(:exec!).with("chmod 600 ~/.ssh/authorized_keys")
      end

      it "appends the key into authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_session).to have_received(:exec!).with("echo '#{public_key}' >> ~/.ssh/authorized_keys")
      end
    end
  end
end
