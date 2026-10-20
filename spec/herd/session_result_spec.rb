# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Herd::Session, "command results" do
  let(:session) { described_class.new(nil, ssh, "secret", log) }
  let(:ssh) { instance_double(Net::SSH::Connection::Session) }
  let(:channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:log) { instance_double(File, puts: nil, print: nil, flush: nil) }
  let(:directory) { Dir.mktmpdir("herd-results-") }

  # Execute the actual composed shell command locally. Only the SSH transport is
  # replaced, so pipefail, exports, directory changes and exit statuses are real.
  before do
    output = nil
    status = nil
    allow(ssh).to receive(:open_channel).and_yield(channel)
    allow(ssh).to receive(:loop)
    allow(channel).to receive(:request_pty).and_yield(channel, true)
    allow(channel).to receive(:exec) do |command, &block|
      output, status = Open3.capture2e("/bin/bash", "-c", command)
      block.call(channel, true)
    end
    allow(channel).to receive(:on_data) do |&block|
      output.b.each_line { |chunk| block.call(channel, chunk) }
    end
    allow(channel).to receive(:on_extended_data)
    allow(channel).to receive(:on_request).with("exit-status") do |&block|
      block.call(channel, instance_double(Net::SSH::Buffer, read_long: status.exitstatus))
    end
  end

  after { FileUtils.remove_entry(directory) }

  describe "#run_result" do
    it "returns output accumulated across chunks and a successful exit status" do
      result = session.run_result("printf 'first\\nготово\\n'")

      expect(result).to be_a(Herd::CommandResult)
      expect(result.output).to eq("first\nготово\n")
      expect(result.output.encoding).to eq(Encoding::UTF_8)
      expect(result.exit_code).to eq(0)
      expect(result).to be_success
    end

    it "returns and logs a failed command without raising" do
      result = session.run_result("printf 'diagnostic'; exit 7")

      expect(result.output).to eq("diagnostic")
      expect(result.exit_code).to eq(7)
      expect(result).not_to be_success
      expect(log).to have_received(:print).with(include('"exit_code":7'))
    end

    it "preserves the exit code of a failed pipeline" do
      expect(session.run_result("false | true").exit_code).to eq(1)
    end

    it "reports a command that could not be found as exit code 127" do
      result = session.run_result("herd_review_no_such_command")

      expect(result.exit_code).to eq(127)
      expect(result.output).to include("herd_review_no_such_command")
    end

    it "honors the caller's directory and environment" do
      result = session.within(directory) do
        session.with_env("HERD_REVIEW_VALUE" => "configured") do
          session.run_result('printf "%s:%s" "$PWD" "$HERD_REVIEW_VALUE"')
        end
      end

      expect(result.output).to eq("#{directory}:configured")
    end

    it "raises if the PTY cannot be obtained" do
      allow(channel).to receive(:request_pty).and_yield(channel, false)

      expect { session.run_result("true") }.to raise_error(Herd::CommandError, "could not obtain pty")
    end
  end

  describe "#run" do
    it "still returns a string on success" do
      expect(session.run("printf 'output'")).to eq("output")
    end

    it "still raises with the command output and exit code on failure" do
      expect { session.run("printf 'diagnostic'; exit 7") }
        .to raise_error(Herd::CommandError, ["diagnostic", 7].to_s)
    end
  end

  describe "#command_success?" do
    it "uses the exit status rather than the output" do
      expect(session.command_success?("printf no")).to be(true)
      expect(session.command_success?("printf yes; exit 1")).to be(false)
    end

    it "propagates transport failures" do
      allow(ssh).to receive(:open_channel).and_raise(Net::SSH::Disconnect, "disconnected")

      expect { session.command_success?("true") }.to raise_error(Net::SSH::Disconnect, "disconnected")
    end
  end

  describe "file predicates" do
    it "tests existing and missing paths without output markers" do
      path = File.join(directory, "file with 'quotes' $literal")
      File.write(path, "yes\nno\n")

      expect(session.file_exists?(path)).to be(true)
      expect(session.file_readable?(path)).to be(true)
      expect(session.file_writable?(path)).to be(true)
      expect(session.symlink?(path)).to be(false)
      expect(session.file_exists?("#{path}.missing")).to be(false)
      expect(session.file_readable?("#{path}.missing")).to be(false)
      expect(session.file_writable?("#{path}.missing")).to be(false)
    end

    it "distinguishes a broken symlink from an existing target" do
      path = File.join(directory, "broken link")
      File.symlink("missing-target", path)

      expect(session.symlink?(path)).to be(true)
      expect(session.file_exists?(path)).to be(false)
    end
  end
end
