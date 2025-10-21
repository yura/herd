# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Host do
  let(:host) { described_class.new("tesla.com", "elon", password: "T0pS3kr3t") }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }

  before do
    allow(Net::SSH).to receive(:start).and_yield(mock_ssh_session)
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)

    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:exec).with("hostname").and_yield(mock_ssh_channel, nil)
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "alpha001")
    allow(mock_ssh_channel).to receive(:on_extended_data)
  end

  describe "#exec" do
    it "starts SSH session" do
      host.exec("hostname")
      expect(Net::SSH).to have_received(:start).with("tesla.com", "elon", password: "T0pS3kr3t", port: 22, timeout: 10)
    end

    it "delegates calls to the SSH session" do
      host.exec("hostname")
      expect(mock_ssh_channel).to have_received(:exec).with("hostname")
    end

    context "when run single command" do
      it "runs given command on the host" do
        expect(host.exec("hostname")).to eq("alpha001")
      end
    end

    context "when run block of commands" do
      it "runs commands in within given block" do
        result = host.exec { hostname }
        expect(result).to eq("alpha001")
      end
    end
  end
end
