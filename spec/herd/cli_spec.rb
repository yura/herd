# frozen_string_literal: true

require "herd"
require "herd/cli"
require "tmpdir"

RSpec.describe Herd::CLI do
  around do |example|
    original = Herd.configuration
    Herd.instance_variable_set(:@configuration, Herd::Configuration.new)
    example.run
  ensure
    Herd.instance_variable_set(:@configuration, original)
  end

  it "applies state store adapter and path" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cache.sqlite3")
      cli = described_class.new(["--state-store", "sqlite", "--state-path", path])
      cli.apply!

      config = Herd.configuration
      expect(config.state_store_adapter).to eq(:sqlite)
      expect(config.state_store_path).to eq(path)
    end
  end

  it "disables state store when value is none" do
    cli = described_class.new(["--state-store", "none"])
    cli.apply!

    expect(Herd.configuration.state_store_adapter).to be_nil
  end

  it "raises on unknown adapter" do
    cli = described_class.new(["--state-store", "foo"])
    expect { cli.parse! }.to raise_error(OptionParser::InvalidArgument)
  end
end
