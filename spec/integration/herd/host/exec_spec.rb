# frozen_string_literal: true

require "dotenv/load"

if ENV["HERD_TEST_HOST"].nil? || ENV["HERD_TEST_USER"].nil?
  abort "Configure remote host connection with .env file. See .env.example"
end

RSpec.describe Herd::Host, "#exec" do
  let(:host) { ENV.fetch("HERD_TEST_HOST", nil) }
  let(:port) { ENV.fetch("HERD_TEST_PORT", nil) }
  let(:user) { ENV.fetch("HERD_TEST_USER", nil) }
  let(:herd_host) { described_class.new(host, user, port: port) }

  context "when running single command passed as a string" do
    it "gives no error on calling true command" do
      expect do
        herd_host.exec "true"
      end.not_to raise_error
    end

    it "gives no error on correct call" do
      expect do
        herd_host.exec "ls"
      end.not_to raise_error
    end

    it "gives no error on piped correct call" do
      expect do
        herd_host.exec "ls | wc -l"
      end.not_to raise_error
    end

    it "raises an error for calling false command (errcode 1)" do
      expect do
        herd_host.exec "false"
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for catting no-existent filed (errcode 1)" do
      expect do
        herd_host.exec "cat non_existent_file"
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for running command with wrong option (errcode 2)" do
      expect do
        herd_host.exec "ls --wrong-option"
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for non-existent command (errcode 127)" do
      expect do
        herd_host.exec "non_existent_command"
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for piped non-existent command (errcodes 127, 0)" do
      expect do
        herd_host.exec "non_existent_command | wc -l"
      end.to raise_error(Herd::CommandError)
    end
  end

  context "when running single command passed as a block" do
    it "gives no error on calling true command" do
      expect do
        herd_host.exec { run("true") }
      end.not_to raise_error
    end

    it "gives no error on correct call" do
      expect do
        herd_host.exec { ls }
      end.not_to raise_error
    end

    it "gives no error on piped correct call" do
      expect do
        herd_host.exec { "ls | wc -l" }
      end.not_to raise_error
    end

    it "raises an error for calling false command (errcode 1)" do
      expect do
        herd_host.exec { run("false") }
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for catting no-existent filed (errcode 1)" do
      expect do
        herd_host.exec { cat "non_existent_file" }
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for running command with wrong option (errcode 2)" do
      expect do
        herd_host.exec { ls "--wrong-option" }
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for non-existent command (errcode 127)" do
      expect do
        herd_host.exec { non_existent_command }
      end.to raise_error(Herd::CommandError)
    end

    it "raises an error for piped non-existent command (errcodes 127, 0)" do
      expect do
        herd_host.exec { run "non_existent_command | wc -l" }
      end.to raise_error(Herd::CommandError)
    end
  end

  context "when running multiple commands passed as a block" do
    subject(:long_block) do
      herd_host.exec do
        run "non_existent_command"
        ls
      end
    end

    it "raises an error for sequential non-existent command (errcodes 127, 0)" do
      expect do
        long_block
      end.to raise_error(Herd::CommandError)
    end
  end
end
