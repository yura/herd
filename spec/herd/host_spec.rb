# frozen_string_literal: true
require "net/ssh"

RSpec.describe Herd::Host do
  let(:host) { described_class.new("tesla.com", "elon", password: "T0pS3kr3t") }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }


  describe "#hostname" do
    before do
      allow(Net::SSH).to receive(:start).and_yield(mock_ssh_session)
      allow(mock_ssh_session).to receive(:exec!).with("hostname").and_yield(nil, :stdout, "alpha001")
    end

    it "returns hostname" do
      result = host.hostname
 
      expect(Net::SSH).to have_received(:start).with("tesla.com", "elon", password: "T0pS3kr3t", port: 22, timeout: 10)
      expect(mock_ssh_session).to have_received(:exec!).with("hostname")
      expect(result).to eq("alpha001")
    end
  end
end
