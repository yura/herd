# frozen_string_literal: true

require "herd"

RSpec.describe Herd::StateStore::Memory do
subject(:store) { described_class.new(clock: clock) }

let(:clock) do
  time = 0
  -> { time += 1; Time.at(time) }
end

  let(:entry) do
    Herd::StateStore::Entry.new(
      status: :success,
      stdout: "ok",
      stderr: "",
      value: { version: "1.0" },
      schema_version: 1
    )
  end

  describe "#write and #fetch" do
    it "persists entries keyed by host/task/signature" do
      store.write(host: "alpha", task: "install", signature: "abc", entry: entry)

      cached = store.fetch(host: "alpha", task: "install", signature: "abc")

      expect(cached.status).to eq(:success)
      expect(cached.stdout).to eq("ok")
      expect(cached.updated_at).to eq(Time.at(1))
    end

    it "returns nil when signature does not match" do
      store.write(host: "alpha", task: "install", signature: "abc", entry: entry)

      expect(store.fetch(host: "alpha", task: "install", signature: "xyz")).to be_nil
    end

    it "returns nil when force flag is true" do
      store.write(host: "alpha", task: "install", signature: "abc", entry: entry)

      expect(store.fetch(host: "alpha", task: "install", signature: "abc", force: true)).to be_nil
    end
  end

  describe "#invalidate" do
    it "drops cached entries for a task" do
      store.write(host: "alpha", task: "install", signature: "one", entry: entry)
      store.write(host: "alpha", task: "install", signature: "two", entry: entry)

      store.invalidate(host: "alpha", task: "install")

      expect(store.fetch(host: "alpha", task: "install", signature: "one")).to be_nil
      expect(store.fetch(host: "alpha", task: "install", signature: "two")).to be_nil
    end

    it "does not affect other tasks or hosts" do
      store.write(host: "alpha", task: "install", signature: "abc", entry: entry)
      store.write(host: "beta", task: "install", signature: "abc", entry: entry)
      store.invalidate(host: "alpha", task: "install")

      expect(store.fetch(host: "beta", task: "install", signature: "abc")).not_to be_nil
    end
  end
end
