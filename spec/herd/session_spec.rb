# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Session do
  let(:session) { described_class.new(mock_ssh_session) }
  let(:mock_ssh_session) do
    instance_double(
      Net::SSH::Connection::Session,
      close: nil,
      closed?: false
    )
  end

  describe "#method_missing" do
    before do
      allow(mock_ssh_session).to receive(:exec!).with("hostname").and_return("alpha001")
    end

    it "delegates calls to SSH session" do
      session.hostname
      expect(mock_ssh_session).to have_received(:exec!).with("hostname")
    end

    it "returns command output" do
      expect(session.hostname).to eq("alpha001")
    end
  end

  describe "#execute" do
    before do
      allow(mock_ssh_session).to receive(:exec!).with("hostname").and_return("alpha001")
    end

    it "runs provided command" do
      result = session.execute("hostname")

      expect(result).to have_attributes(
        value: "alpha001",
        stdout: "alpha001",
        stderr: ""
      )
    end

    it "evaluates provided block" do
      result = session.execute { hostname }

      expect(result).to have_attributes(
        value: "alpha001",
        stdout: "alpha001",
        stderr: ""
      )
    end
  end

  describe "#close" do
    it "closes underlying SSH session" do
      session.close
      expect(mock_ssh_session).to have_received(:close)
    end
  end

  describe "#closed?" do
    it "delegates to SSH session" do
      allow(mock_ssh_session).to receive(:closed?).and_return(true)
      expect(session).to be_closed
    end
  end

  describe "error handling" do
    it "stores last result when command raises" do
      allow(mock_ssh_session).to receive(:exec!).with("hostname") do |&block|
        block&.call(nil, :stderr, "permission denied")
        nil
      end

      expect { session.execute("hostname") }.to raise_error(Herd::CommandError)

      result = session.last_result
      expect(result.stderr).to include("permission denied")
    end
  end
end
