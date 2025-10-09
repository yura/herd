# frozen_string_literal: true

require "herd"
require "herd/cli"
require "tmpdir"
require "json"

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

  it "executes recipe via run command" do
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, "recipe.rb")
      flag_path = File.join(dir, "flag.txt")

      File.write(recipe_path, <<~RUBY)
        Herd::DSL.define do
          task "touch" do |ctx|
            File.write(ctx[:flag], "ok")
            Herd::ExecutionResult.new(value: "ok", stdout: "ok\n", stderr: "")
          end
        end
      RUBY

      cli = described_class.new([
                                  "run",
                                  recipe_path,
                                  "--host", "alpha",
                                  "--context", "flag=#{flag_path}"
                                ])

      expect { cli.run! }.to output(/Host alpha: success/).to_stdout
      expect(File.read(flag_path)).to eq("ok")
    end
  end

  it "loads params from file and supports multiple hosts" do
    Dir.mktmpdir do |dir|
      params_path = File.join(dir, "params.yml")
      File.write(params_path, "message: from_file\n")

      summary_path = File.join(dir, "summary.txt")
      json_path = File.join(dir, "report.json")

      recipe_path = File.join(dir, "recipe.rb")
      File.write(recipe_path, <<~RUBY)
        Herd::DSL.define do
          task "write" do |ctx|
            host = ctx[:host].to_s
            message = ctx[:params][:message].to_s
            output = File.join(ctx[:dir], host + ".txt")
            File.write(output, message)
            Herd::ExecutionResult.new(value: message, stdout: message + "\n", stderr: "")
          end
        end
      RUBY

      cli = described_class.new([
                                  "run",
                                  recipe_path,
                                  "--host", "alpha,beta",
                                  "--concurrency", "2",
                                  "--params-file", params_path,
                                  "--param", "message=override",
                                  "--context", "dir=#{dir}",
                                  "--report-summary", summary_path,
                                  "--report-json", json_path
                                ])

      expect { cli.run! }.to output(/Host alpha: success.*Host beta: success/m).to_stdout

      %w[alpha beta].each do |host|
        expect(File.read(File.join(dir, "#{host}.txt"))).to eq("override")
      end

      expect(File.read(summary_path)).to include("write@alpha")
      data = JSON.parse(File.read(json_path))
      expect(data["events"].size).to be >= 2
    end
  end
end
