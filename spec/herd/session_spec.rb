# frozen_string_literal: true

# Channel handling (sudo prompt, stderr, exit status, stdin, timeout) is in session_transport_spec.
RSpec.describe Herd::Session do
  let(:session) { described_class.new(nil, nil, "T0pS3kr3t", log) }
  let(:log) { StringIO.new }

  describe "#method_missing" do
    it "runs the call as a command" do
      allow(session).to receive(:run_result).and_return(Herd::CommandResult.new(stdout: "alpha001", exit_code: 0))

      expect(session.hostname).to eq("alpha001")
      expect(session).to have_received(:run_result).with("hostname")
    end
  end

  describe "#respond_to?" do
    it "answers for OS commands without raising" do
      expect(session.respond_to?(:hostname)).to be(true)
      expect(session.respond_to?(:no_such_thing)).to be(false)
    end
  end

  describe "#run_result" do
    it "refuses stdin on a PTY, where the terminal would rewrite it" do
      expect { session.run_result("cat", stdin: "x") }.to raise_error(ArgumentError)
    end
  end

  describe "#with_env" do
    it "refuses names that aren't variable names before running anything" do
      allow(session).to receive(:ssh_execute)

      ["HERD-INVALID", "A B", "1X", "X;rm"].each do |name|
        expect { session.with_env(name => "x") { session.run("true") } }.to raise_error(ArgumentError)
      end
      expect(session).not_to have_received(:ssh_execute)
    end
  end

  describe "sensitive: true" do
    before do
      allow(session).to receive(:ssh_execute).and_return(Herd::CommandResult.new(stdout: "hunter22", exit_code: 1))
    end

    it "keeps the command and output out of the log and the exception" do
      expect { session.run("echo hunter22; exit 1", sensitive: true) }
        .to raise_error(Herd::CommandError) { |e| expect(e.message).not_to include("hunter22") }
      expect(log.string).not_to include("hunter22")
      expect(log.string).to include("[redacted]")
    end
  end

  describe "#command_success?" do
    it "propagates transport failures instead of answering false" do
      allow(session).to receive(:ssh_execute).and_raise(Net::SSH::Disconnect, "disconnected")

      expect { session.command_success?("true") }.to raise_error(Net::SSH::Disconnect, "disconnected")
    end
  end
end
