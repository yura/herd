# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Host do
  let(:host) { described_class.new("tesla.com", "elon", password: "T0pS3kr3t") }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }

  describe "#exec" do
    before do
      allow(Net::SSH).to receive(:start).and_yield(mock_ssh_session)
      allow(mock_ssh_session).to receive(:exec!).with("hostname").and_yield(nil, :stdout, "alpha001")
    end

    it "starts SSH session" do
      host.exec("hostname")
      expect(Net::SSH).to have_received(:start).with("tesla.com", "elon", password: "T0pS3kr3t", port: 22, timeout: 10)
    end

    it "delegates calls to the SSH session" do
      host.exec("hostname")
      expect(mock_ssh_session).to have_received(:exec!).with("hostname")
    end

    context "when run single command" do
      subject(:result) { host.exec("hostname") }

      let(:expected_attributes) do
        {
          value: "alpha001",
          stdout: "alpha001",
          stderr: "",
          exception: nil
        }
      end

      it "returns execution result" do
        expect(result).to have_attributes(expected_attributes)
      end
    end

    context "when run block of commands" do
      it "records commands executed" do
        expect(host.exec { hostname }.commands.map { |entry| entry[:command] }).to eq(["hostname"])
      end
    end

    context "when command fails" do
      before do
        allow(mock_ssh_session).to receive(:exec!).with("fail").and_yield(nil, :stderr, "boom")
      end

      it "captures exception details" do
        result = host.exec { send(:method_missing, :fail) }

        expect(result).to have_attributes(
          exception: an_instance_of(Herd::CommandError),
          stderr: include("boom")
        )
      end
    end
  end
end
