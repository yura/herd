# frozen_string_literal: true

require "herd"

RSpec.describe Herd::TaskGraph do
  let(:report) { Herd::RunReport.new }
  let(:store) { Herd::StateStore::Memory.new(clock: -> { Time.at(1) }) }
  let(:graph) { described_class.new(report: report, state_store: store, signature_builder: signature_builder) }

  let(:signature_builder) do
    ->(task_name, params) { "sig:#{task_name}:#{params[:version]}" }
  end

  before do
    graph.task("install") do |_ctx|
      Herd::ExecutionResult.new(value: "install", stdout: "install\n", stderr: "")
    end

    graph.task("configure", depends_on: ["install"]) do |_ctx|
      Herd::ExecutionResult.new(value: "configure", stdout: "configure\n", stderr: "")
    end
  end

  it "uses cache hits to skip execution" do
    entry = Herd::StateStore::Entry.new(status: :success, stdout: "install\n", stderr: "", value: "install", schema_version: 1)
    store.write(host: "alpha", task: "install", signature: "sig:install:v1", entry: entry)

    result = graph.run(host: "alpha", context: nil, params: { version: "v1" })

    expect(result["install"].status).to eq(:cached)
    expect(result["configure"].status).to eq(:success)

    cached_event = report.events.find { |event| event[:task] == "install" }
    expect(cached_event[:status]).to eq(:skipped)
    expect(cached_event[:skip_reason]).to include("cache hit")
  end

  it "forces re-execution when --force is true" do
    entry = Herd::StateStore::Entry.new(status: :success, stdout: "install\n", stderr: "", value: "install", schema_version: 1)
    store.write(host: "alpha", task: "install", signature: "sig:install:v1", entry: entry)

    graph.run(host: "alpha", context: nil, params: { version: "v1" }, force: true)

    event = report.events.select { |e| e[:task] == "install" }.last
    expect(event[:status]).to eq(:success)
  end
end
