# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Runner do
  let(:runner) { described_class.new(hosts) }
  let(:hosts) { [first_host, second_host] }
  let(:first_host) { instance_double(Herd::Host) }
  let(:second_host) { instance_double(Herd::Host) }

  describe "exec" do
    context "when run single command" do
      before do
        allow(first_host).to receive(:exec).with("hostname").and_return("alpha001")
        allow(second_host).to receive(:exec).with("hostname").and_return("alpha002")
      end

      it "runs the command in parallel on all hosts" do
        expect(runner.exec("hostname")).to eq(%w[alpha001 alpha002])
      end
    end

    context "when run blocks of commands" do
      before do
        allow(first_host).to receive(:exec).with(nil).and_return("alpha001")
        allow(second_host).to receive(:exec).with(nil).and_return("alpha002")
      end

      it "runs the command in parallel on all hosts" do
        expect(runner.exec { hostname }).to eq(%w[alpha001 alpha002])
      end
    end
  end
end
