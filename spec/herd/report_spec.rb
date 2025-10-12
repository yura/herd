# frozen_string_literal: true

RSpec.describe Herd::Report do
  let(:host) do
    instance_double(
      Herd::Host,
      host: "example.com",
      user: "deploy",
      ssh_options: { port: 22 }
    )
  end
  let(:result) do
    Herd::ExecutionResult.new(
      host: host,
      value: "ok",
      stdout: "ok",
      stderr: "",
      commands: [],
      exception: nil,
      started_at: Time.now,
      finished_at: Time.now,
      duration: 0.0
    )
  end

  it "collects successful events", :aggregate_failures do
    report = described_class.new
    report.add(task_name: :uptime, result: result)

    expect(report.events.size).to eq(1)
    expect(report).to be_success
    expect(report.summary).to include("deploy@example.com:22")
  end

  it "marks failures when exception present", :aggregate_failures do
    failure = result.dup.tap { |copy| copy.exception = RuntimeError.new("boom") }
    report = described_class.new.tap { |r| r.add(task_name: :uptime, result: failure) }

    expect(report).not_to be_success
    expect(report.summary).to include("failed")
  end
end
