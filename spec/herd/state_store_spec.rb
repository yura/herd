# frozen_string_literal: true

require "herd"
require "tmpdir"
require "fileutils"

RSpec.shared_examples "state store adapter" do
  let(:clock) do
    time = 0
    -> { time += 1; Time.at(time) }
  end

  subject(:store) { build_store.call(clock) }

  after do
    store.close if store.respond_to?(:close)
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

RSpec.describe Herd::StateStore::Memory do
  it_behaves_like "state store adapter" do
    let(:build_store) { ->(clock_proc) { described_class.new(clock: clock_proc) } }
  end
end

RSpec.describe Herd::StateStore::SQLite do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "state.sqlite3") }

  after do
    FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir)
  end

  it_behaves_like "state store adapter" do
    let(:build_store) { ->(clock_proc) { described_class.new(path: db_path, clock: clock_proc) } }
  end

  it "persists entries across instances" do
    clock = -> { Time.at(1) }
    first = described_class.new(path: db_path, clock: clock)
    entry = Herd::StateStore::Entry.new(status: :success, stdout: "ok", stderr: "", value: nil, schema_version: 1)
    first.write(host: "alpha", task: "install", signature: "abc", entry: entry)
    first.close

    second = described_class.new(path: db_path, clock: clock)
    cached = second.fetch(host: "alpha", task: "install", signature: "abc")
    expect(cached).not_to be_nil
    second.close
  end
end
