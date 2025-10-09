# frozen_string_literal: true

require "herd"

RSpec.describe Herd::DSL do
  around do |example|
    original = Herd.configuration
    Herd.instance_variable_set(:@configuration, Herd::Configuration.new)
    example.run
  ensure
    Herd.instance_variable_set(:@configuration, original)
  end

  it "builds a task graph recipe with defaults" do
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
    result = recipe.run(host: "alpha", context: context)

    expect(context[:executed]).to eq(%i[install configure])
    expect(result.success?).to be(true)
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
