# frozen_string_literal: true

require "herd"

RSpec.describe Herd::TaskGraph do
  let(:report) { Herd::RunReport.new }
  let(:graph) { described_class.new(report: report) }

  describe "concurrency" do
    it "limits execution to specified concurrency" do
      context = { mutex: Mutex.new, running: 0, max: 0 }

      %w[a b].each do |name|
        graph.task(name) do |ctx|
          ctx[:mutex].synchronize do
            ctx[:running] += 1
            ctx[:max] = [ctx[:max], ctx[:running]].max
          end
          sleep 0.05
        ensure
          ctx[:mutex].synchronize { ctx[:running] -= 1 }
        end
      end

      graph.task("c", depends_on: %w[a b]) do |_ctx|
        Herd::ExecutionResult.new(value: "c", stdout: "c\n", stderr: "")
      end

      context[:max] = 0
      result = graph.run(host: "alpha", context: context, params: {}, concurrency: 2)

      expect(result["a"].status).to eq(:success)
      expect(result["b"].status).to eq(:success)
      expect(result["c"].status).to eq(:success)
      expect(context[:max]).to be >= 2
    end

    it "skips dependents when prerequisites fail" do
      graph.task("install") { |_ctx| raise "boom" }
      graph.task("configure", depends_on: ["install"]) { |_ctx| raise "should not run" }

      result = graph.run(host: "alpha", context: {}, params: {}, concurrency: 4)

      expect(result["install"].status).to eq(:failed)
      expect(result["configure"].status).to eq(:skipped)
      expect(result["configure"].skip_reason).to include("install failed")
    end
  end
end
