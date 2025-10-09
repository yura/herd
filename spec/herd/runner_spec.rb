# frozen_string_literal: true

require "net/ssh"
require "herd/run_report"

RSpec.describe Herd::Runner do
  let(:runner) { described_class.new(hosts) }
  let(:hosts) { [first_host, second_host] }
  let(:first_host) { instance_double(Herd::Host) }
  let(:second_host) { instance_double(Herd::Host) }

  describe "exec" do
    let(:run_report) { Herd::RunReport.new }

    context "when run single command" do
      before do
        allow(first_host).to receive(:exec).with("hostname").and_return("alpha001")
        allow(second_host).to receive(:exec).with("hostname").and_return("alpha002")
        allow(first_host).to receive(:host).and_return("first.example")
        allow(second_host).to receive(:host).and_return("second.example")
      end

      it "runs the command in parallel on all hosts" do
        expect(runner.exec("hostname")).to eq(%w[alpha001 alpha002])
      end

      it "records successful executions in the report" do
        runner.exec("hostname", task: "check hostname", report: run_report)

        expect(run_report.events).to include(
          include(
            host: "first.example",
            task: "check hostname",
            command: "hostname",
            status: :success,
            stdout: "alpha001",
            stderr: nil
          ),
          include(
            host: "second.example",
            task: "check hostname",
            command: "hostname",
            status: :success,
            stdout: "alpha002",
            stderr: nil
          )
        )
      end
    end

    context "when run blocks of commands" do
      before do
        allow(first_host).to receive(:exec).with(nil).and_return("alpha001")
        allow(second_host).to receive(:exec).with(nil).and_return("alpha002")
        allow(first_host).to receive(:host).and_return("first.example")
        allow(second_host).to receive(:host).and_return("second.example")
      end

      it "runs the command in parallel on all hosts" do
        expect(runner.exec { hostname }).to eq(%w[alpha001 alpha002])
      end

      it "records failures with exception metadata" do
        error = RuntimeError.new("boom")
        allow(first_host).to receive(:exec).with(nil).and_raise(error)

        expect do
          runner.exec(task: "block run", report: run_report) { hostname }
        end.to raise_error(RuntimeError)

        event = run_report.events.find { |entry| entry[:host] == "first.example" }

        expect(event).to include(
          task: "block run",
          command: nil,
          status: :failed,
          stdout: nil,
          stderr: nil
        )

        expect(event[:exception]).to include(
          :class,
          :message,
          :backtrace
        )
      end
    end
  end
end
