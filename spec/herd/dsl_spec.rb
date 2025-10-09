# frozen_string_literal: true

require "herd"
require "json"
require "tmpdir"

RSpec.describe Herd::DSL do
  around do |example|
    original = Herd.configuration
    Herd.instance_variable_set(:@configuration, Herd::Configuration.new)
    example.run
  ensure
    Herd.instance_variable_set(:@configuration, original)
  end

  it "builds a task graph recipe with defaults" do
    Dir.mktmpdir do |dir|
      summary_path = File.join(dir, "summary.txt")
      json_path = File.join(dir, "report.json")

      recipe = described_class.define do
        defaults version: "v1"

        task "install" do |ctx|
          ctx[:executed] << :install
          Herd::ExecutionResult.new(value: "install", stdout: "install\n", stderr: "")
        end

        task "configure",
             depends_on: ["install"],
             signature_params: ->(ctx, params) { { version: params[:version], hash: ctx[:hash] } } do |ctx|
          ctx[:executed] << :configure
          Herd::ExecutionResult.new(value: "configure", stdout: "configure\n", stderr: "")
        end
      end

      context = { executed: [], hash: "abc" }
      result = recipe.run(
        host: "alpha",
        context: context,
        summary_path: summary_path,
        json_path: json_path
      )

      expect(context[:executed]).to eq(%i[install configure])
      expect(result.success?).to be(true)
      expect(File.read(summary_path)).to include("configure@alpha")
      expect(JSON.parse(File.read(json_path))["events"].size).to eq(2)
    end
  end

  it "respects state store across runs" do
    store = Herd::StateStore::Memory.new(clock: -> { Time.at(1) })
    recipe = described_class.define do
      defaults version: "v1"

      task "install", signature_params: ->(_, params) { params } do |ctx|
        ctx[:runs] ||= 0
        ctx[:runs] += 1
        Herd::ExecutionResult.new(value: "install", stdout: "install\n", stderr: "")
      end
    end

    context = {}
    recipe.run(host: "alpha", context: context, state_store: store)
    expect(context[:runs]).to eq(1)

    recipe.run(host: "alpha", context: context, state_store: store)
    expect(context[:runs]).to eq(1)
  end
end
