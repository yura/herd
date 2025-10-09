# frozen_string_literal: true

require "herd"

RSpec.describe Herd::TaskGraph do
  let(:report) { Herd::RunReport.new }
  let(:graph) { described_class.new(report: report) }

  describe "execution order" do
    it "runs tasks respecting dependencies" do
      executed = []

      graph.task("install") do |ctx|
        ctx << "install"
        Herd::ExecutionResult.new(value: :install, stdout: "install\n", stderr: "")
      end

      graph.task("configure", depends_on: %w[install]) do |ctx|
        ctx << "configure"
        Herd::ExecutionResult.new(value: :configure, stdout: "configure\n", stderr: "")
      end

      result = graph.run(host: "alpha", context: executed)

      expect(executed).to eq(%w[install configure])
      expect(result.success?).to be(true)
      expect(result["install"].status).to eq(:success)
      expect(result["configure"].status).to eq(:success)

      summary = report.summary
      expect(summary).to include("install@alpha")
      expect(summary).to include("configure@alpha")
    end
  end

  describe "failure propagation" do
    it "skips dependent tasks when prerequisite fails" do
      graph.task("install") do |_ctx|
        raise "boom"
      end

      graph.task("configure", depends_on: %w[install]) do |_ctx|
        raise "should not run"
      end

      result = graph.run(host: "alpha", context: [])

      expect(result.success?).to be(false)
      expect(result["install"].status).to eq(:failed)
      expect(result["install"].error.message).to eq("boom")
      expect(result["configure"].status).to eq(:skipped)
      expect(result["configure"].skip_reason).to include("install")

      skipped_event = report.events.find { |event| event[:task] == "configure" }
      expect(skipped_event[:status]).to eq(:skipped)
      expect(skipped_event[:skip_reason]).to include("install")
    end
  end
end

