# frozen_string_literal: true

require "net/ssh"

RSpec.describe Herd::Runner do
  let(:first_host) { instance_double(Herd::Host) }
  let(:second_host) { instance_double(Herd::Host) }
  let(:runner) { described_class.new([first_host, second_host]) }

  describe "exec" do
    let(:result_one) { instance_double(Herd::ExecutionResult, value: "alpha001") }
    let(:result_two) { instance_double(Herd::ExecutionResult, value: "alpha002") }

    context "when run single command" do
      before do
        allow(first_host).to receive(:exec).with("hostname").and_return(result_one)
        allow(second_host).to receive(:exec).with("hostname").and_return(result_two)
      end

      it "runs the command in parallel on all hosts", :aggregate_failures do
        results = runner.exec("hostname")

        expect(results.map(&:value)).to eq(%w[alpha001 alpha002])
        expect(results).to contain_exactly(result_one, result_two)
      end
    end

    context "when run blocks of commands" do
      before do
        allow(first_host).to receive(:exec).with(nil).and_return(result_one)
        allow(second_host).to receive(:exec).with(nil).and_return(result_two)
      end

      it "runs the command in parallel on all hosts" do
        results = runner.exec { hostname }

        expect(results.map(&:value)).to eq(%w[alpha001 alpha002])
      end
    end
  end
end
