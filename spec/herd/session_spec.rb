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
end
