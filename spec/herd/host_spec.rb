# frozen_string_literal: true

require_relative "../support/ssh_story"

require "json"
require "net/ssh"
require "tmpdir"

RSpec.describe Herd::Host, :ssh_story do
  let(:host) do
    described_class.new("tesla.com", { user: "elon", password: "T0pS3kr3t" },
                        { hostname: "alpha", root_password: "r00tPassw0rd", api_key: "abc-123-xyz", sensitive: [:api_key] })
  end

  around do |example|
    Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
  end

  before do
    story do |server|
      channel = server.opens_channel
      sends_request_pty_with_reply(channel)
      channel.sends_exec("set -o pipefail; hostname")
      channel.gets_data("alpha001")
      channel.gets_exit_status(0)
      channel.gets_close
      channel.sends_close
    end
    # The connection is made inside assert_scripted, where the scripted socket counts as IO.
    allow(Net::SSH).to receive(:start) { |*, &block| block.call(connection) }
  end

  def log_lines = File.readlines(Dir["log/**/*.jsonl"].fetch(0)).map { |line| JSON.parse(line) }

  describe "#exec" do
    it "starts SSH session" do
      assert_scripted { host.exec("hostname") }
      expect(Net::SSH).to have_received(:start).with("tesla.com", "elon",
                                                     hash_including(password: "T0pS3kr3t", port: 22, timeout: 10))
    end

    it "runs a single command and returns its output" do
      assert_scripted { expect(host.exec("hostname")).to eq("alpha001") }
    end

    it "runs a block of commands" do
      assert_scripted { expect(host.exec { hostname }).to eq("alpha001") }
    end
  end

  describe "#info" do
    it "prints with the hostname var, or the address" do
      expect { host.info("hello") }.to output("[alpha] hello\n").to_stdout
      expect { described_class.new("10.0.0.1", user: "x").info("hi") }.to output("[10.0.0.1] hi\n").to_stdout
    end
  end

  describe "the log" do
    it "is JSON Lines starting with the vars" do
      assert_scripted { host.exec("hostname") }

      expect(log_lines.first.keys).to eq(["vars"])
      expect(log_lines.last).to include("command" => "hostname", "output" => "alpha001", "exit_code" => 0)
    end

    it "is readable only by its owner" do
      assert_scripted { host.exec("hostname") }

      expect(format("%o", File.stat(Dir["log/**/*.jsonl"].fetch(0)).mode & 0o777)).to eq("600")
    end

    it "redacts password-like vars and the ones listed in sensitive:" do
      assert_scripted { host.exec("hostname") }

      vars = log_lines.first["vars"]
      expect(vars).to include("root_password" => "[redacted]", "api_key" => "[redacted]", "hostname" => "alpha")
      expect(File.read(Dir["log/**/*.jsonl"].fetch(0))).not_to include("r00tPassw0rd", "abc-123-xyz", "T0pS3kr3t")
    end

    it "never overwrites an earlier log" do
      allow(Time).to receive(:now).and_return(Time.at(1_700_000_000))
      assert_scripted { host.exec("hostname") }
      2.times do
        other = described_class.new("tesla.com", user: "elon")
        other.open_log
        other.close_log
      end

      expect(Dir["log/**/*.jsonl"].size).to eq(3)
    end
  end
end
