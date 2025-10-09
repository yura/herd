# frozen_string_literal: true

require "herd"

RSpec.describe Herd::TaskGraph do
  let(:report) { Herd::RunReport.new }
  let(:store) { Herd::StateStore::Memory.new(clock: -> { Time.at(1) }) }
  let(:graph) { described_class.new(report: report, state_store: store, signature_builder: signature_builder) }

  let(:signature_builder) { nil }

  before do
    graph.task("install") do |_ctx|
      Herd::ExecutionResult.new(value: "install", stdout: "install\n", stderr: "")
    end

    graph.task(
      "configure",
      depends_on: ["install"],
      signature_params: ->(ctx, params) { { version: params[:version], config_hash: ctx[:config_hash] } }
    ) do |ctx|
      ctx[:runs] ||= 0
      ctx[:runs] += 1
      Herd::ExecutionResult.new(value: "configure", stdout: "configure\n", stderr: "")
    end
  end

  it "uses cache hits to skip execution" do
    builder = graph.send(:signature_builder)
    install_signature = builder.call("install", { version: "v1" })
    entry = Herd::StateStore::Entry.new(status: :success, stdout: "install\n", stderr: "", value: "install", schema_version: 1)
    store.write(host: "alpha", task: "install", signature: install_signature, entry: entry)

    context = { config_hash: "abc" }
    result = graph.run(host: "alpha", context: context, params: { version: "v1" })

    expect(result["install"].status).to eq(:cached)
    expect(result["configure"].status).to eq(:success)

    cached_event = report.events.find { |event| event[:task] == "install" }
    expect(cached_event[:status]).to eq(:skipped)
    expect(cached_event[:skip_reason]).to include("cache hit")
  end

  it "forces re-execution when --force is true" do
    builder = graph.send(:signature_builder)
    install_signature = builder.call("install", { version: "v1" })
    entry = Herd::StateStore::Entry.new(status: :success, stdout: "install\n", stderr: "", value: "install", schema_version: 1)
    store.write(host: "alpha", task: "install", signature: install_signature, entry: entry)

    graph.run(host: "alpha", context: { config_hash: "abc" }, params: { version: "v1" }, force: true)

    event = report.events.select { |e| e[:task] == "install" }.last
    expect(event[:status]).to eq(:success)
  end

  it "builds distinct signatures from context" do
    context = { config_hash: "abc" }
    graph.run(host: "alpha", context: context, params: { version: "v1" })

    builder = graph.send(:signature_builder)
    configure_signature = builder.call("configure", { version: "v1", config_hash: "abc" })
    cached = store.fetch(host: "alpha", task: "configure", signature: configure_signature)
    expect(cached).not_to be_nil

    context[:config_hash] = "def"
    graph.run(host: "alpha", context: context, params: { version: "v1" })

    expect(context[:runs]).to eq(2)
  end
end
