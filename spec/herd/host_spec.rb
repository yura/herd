# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Host do
  let(:host) { described_class.new("tesla.com", "elon", password: "T0pS3kr3t") }
  let(:mock_ssh_session) do
    instance_double(
      Net::SSH::Connection::Session,
      close: nil,
      closed?: false
    )
  end

  before do
    allow(Net::SSH).to receive(:start).and_return(mock_ssh_session)
    allow(mock_ssh_session).to receive(:exec!).with("hostname").and_return("alpha001")
  end

  describe "#exec" do
    it "starts SSH session" do
      host.exec("hostname")
      expect(Net::SSH).to have_received(:start).with("tesla.com", "elon", password: "T0pS3kr3t", port: 22, timeout: 10)
    end

    it "delegates calls to the SSH session" do
      host.exec("hostname")
      expect(mock_ssh_session).to have_received(:exec!).with("hostname")
    end

    context "when run single command" do
      it "runs given command on the host" do
        expect(host.exec("hostname")).to eq("alpha001")
        expect(host.last_execution.stdout).to eq("alpha001")
        expect(host.last_execution.stderr).to eq("")
      end
    end

    context "when run block of commands" do
      it "runs commands in within given block" do
        result = host.exec { hostname }
        expect(result).to eq("alpha001")
        expect(host.last_execution.stdout).to eq("alpha001")
        expect(host.last_execution.stderr).to eq("")
      end
    end

    it "reuses persistent session between executions" do
      host.exec("hostname")
      host.exec("hostname")

      expect(Net::SSH).to have_received(:start).once
    end

    it "closes persistent session via #close" do
      host.exec("hostname")
      host.close

      expect(mock_ssh_session).to have_received(:close)
    end

    it "reconnects after execution failure" do
      failing_session = instance_double(
        Net::SSH::Connection::Session,
        exec!: nil,
        close: nil,
        closed?: false
      )
      working_session = mock_ssh_session

      allow(Net::SSH).to receive(:start).and_return(failing_session, working_session)
      allow(failing_session).to receive(:exec!).with("hostname").and_raise(IOError, "boom")
      allow(working_session).to receive(:exec!).with("hostname").and_return("alpha001")

      expect { host.exec("hostname") }.to raise_error(IOError)
      expect(host.last_execution.stdout).to eq("")
      expect(host.last_execution.stderr).to eq("")

      expect(host.exec("hostname")).to eq("alpha001")
      expect(host.last_execution.stdout).to eq("alpha001")
      expect(host.last_execution.stderr).to eq("")

      expect(Net::SSH).to have_received(:start).twice
      expect(failing_session).to have_received(:close)
    end
  end
end
