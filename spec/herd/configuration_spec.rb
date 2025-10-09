# frozen_string_literal: true

require "herd"
require "tmpdir"

RSpec.describe Herd::Configuration do
  around do |example|
    original = Herd.configuration
    Herd.instance_variable_set(:@configuration, Herd::Configuration.new)
    example.run
  ensure
    Herd.instance_variable_set(:@configuration, original)
  end

  describe "state store defaults" do
    it "does not build store when adapter is nil" do
      Herd.configure { |config| config.state_store_adapter = nil }

      config = Herd.configuration
      expect(config.state_store_adapter).to be_nil
      expect(config.build_state_store).to be_nil
    end

    it "builds SQLite store when configured" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "state.sqlite3")
        Herd.configure do |config|
          config.state_store_adapter = :sqlite
          config.state_store_path = path
        end

        store = Herd.configuration.build_state_store
        expect(store).to be_a(Herd::StateStore::SQLite)
        store.close
      end
    end
  end

  describe "configuration DSL" do
    it "allows overriding adapter via configure" do
      Herd.configure { |config| config.state_store_adapter = :memory }

      store = Herd.configuration.build_state_store
      expect(store).to be_a(Herd::StateStore::Memory)
    end
  end
end
