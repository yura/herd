# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Session do
  let(:session) { described_class.new(nil, mock_ssh_session, "T0pS3kr3t", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  before do
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)

    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:exec).with("set -o pipefail; hostname").and_yield(mock_ssh_channel, nil)
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "alpha001")
    allow(mock_ssh_channel).to receive(:on_extended_data)
    allow(mock_ssh_channel).to receive(:on_request).with("exit-status").and_yield(nil,
                                                                                  instance_double(Net::SSH::Buffer,
                                                                                                  read_long: 0))
  end

  describe "#method_missing" do
    before do
      allow(mock_ssh_session).to receive(:exec!).with("set -o pipefail; hostname").and_yield(nil, :stdout, "alpha001")
    end

    it "delegates calls to SSH session" do
      session.hostname
      expect(mock_ssh_channel).to have_received(:exec).with("set -o pipefail; hostname")
    end

    it "returns command output" do
      expect(session.hostname).to eq("alpha001")
    end
  end

  describe "#sudo" do
    before do
      allow(mock_ssh_channel).to receive(:exec).with("set -o pipefail; sudo -p 'HERD_SUDO: ' whoami")
                                               .and_yield(mock_ssh_channel, nil)
      allow(mock_ssh_channel).to receive(:send_data)
      allow(mock_ssh_channel).to receive(:on_data)
        .and_yield(nil, "HERD_SUDO: ").and_yield(nil, "*****").and_yield(nil, "****\r\nroot\r\n")
    end

    it "answers the password prompt" do
      session.sudo("whoami")
      expect(mock_ssh_channel).to have_received(:send_data).with("T0pS3kr3t\n")
    end

    it "drops the pwfeedback asterisks from the output" do
      expect(session.sudo("whoami")).to eq("root\r\n")
    end
  end

  context "with AuthorizedKeys commands" do
    it "preprends authorized keys helpers" do
      expect(described_class.ancestors).to include(Herd::Commands::AuthorizedKeys)
    end

    describe "#authorized_keys" do
      before do
        allow(mock_ssh_channel).to receive(:exec)
          .with("set -o pipefail; test -e \"$HOME\"/.ssh/authorized_keys")
          .and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to receive(:exec)
          .with("set -o pipefail; cat -- \"$HOME\"/.ssh/authorized_keys")
          .and_yield(mock_ssh_channel, nil)

        responses = ["", "key1\nkey2\n"]
        allow(mock_ssh_channel).to receive(:on_data) { |&blk| blk.call(nil, responses.shift) } # rubocop:disable RSpec/Yield
      end

      it "returns list of remote authorized keys" do
        expect(session.authorized_keys).to eq(%w[key1 key2])
      end
    end

    describe "#add_authorized_key" do
      let(:public_key) { "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC" }

      before do
        allow(mock_ssh_channel).to receive(:exec).with("set -o pipefail; touch -- \"$HOME\"/.ssh/authorized_keys")
                                                 .and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to receive(:exec).with("set -o pipefail; sudo -p 'HERD_SUDO: ' chmod -- 600 \"$HOME\"/.ssh/authorized_keys")
                                                 .and_yield(mock_ssh_channel, nil)
        allow(mock_ssh_channel).to \
          receive(:exec).with("set -o pipefail; tee -a -- \"$HOME\"/.ssh/authorized_keys << \"HERD_EOF\"\n#{public_key}\nHERD_EOF")
                        .and_yield(mock_ssh_channel, nil)
      end

      it "touches the authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_channel).to have_received(:exec).with("set -o pipefail; touch -- \"$HOME\"/.ssh/authorized_keys")
      end

      it "sets strict permissions on authorized keys file" do
        session.add_authorized_key(public_key)

        expect(mock_ssh_channel).to have_received(:exec).with("set -o pipefail; sudo -p 'HERD_SUDO: ' chmod -- 600 \"$HOME\"/.ssh/authorized_keys")
      end

      it "appends the key into authorized keys file" do
        session.add_authorized_key(public_key)
        command = "set -o pipefail; tee -a -- \"$HOME\"/.ssh/authorized_keys << \"HERD_EOF\"\n#{public_key}\nHERD_EOF"
        expect(mock_ssh_channel).to have_received(:exec).with(command)
      end
    end
  end
end
