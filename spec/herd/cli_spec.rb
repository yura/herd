# frozen_string_literal: true

require "stringio"
require "herd/cli"

RSpec.describe Herd::CLI do
  describe "#run" do
    context "with run command" do
      subject(:run_cli) { cli.run }

      let(:cli) { described_class.new(arguments) }
      let(:arguments) { ["run", "recipe.rb", "--hosts=hosts.csv"] }
      let(:command) { instance_double(Herd::CLI::RunCommand, execute: 0) }

      before do
        allow(Herd::CLI::RunCommand).to receive(:new).and_return(command)
      end

      it "returns exit code from run command" do
        expect(run_cli).to eq(0)
      end

      it "builds run command with remaining arguments" do
        run_cli
        expect(Herd::CLI::RunCommand).to have_received(:new).with(["recipe.rb", "--hosts=hosts.csv"])
      end

      it "executes run command" do
        run_cli
        expect(command).to have_received(:execute)
      end
    end

    it "prints usage when command is missing" do
      expect { described_class.new([]).run }.to output(/Usage:/).to_stderr
    end
  end
end
