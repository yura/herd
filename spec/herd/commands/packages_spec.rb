# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Herd::Commands::Packages do
  let(:session) { Herd::Session.new(nil, nil, nil, nil) }
  let(:bin) { Dir.mktmpdir }

  # Runs the real detection command with only the given fake tools on PATH.
  def detect_with(*tools)
    tools.each { |tool| File.write(File.join(bin, tool), "#!/bin/sh\n").then { File.chmod(0o755, File.join(bin, tool)) } }
    allow(session).to receive(:run) { |cmd| Open3.capture2({ "PATH" => bin }, "/bin/bash", "-c", cmd).first }
    session.send(:package_manager)
  end

  after { FileUtils.remove_entry(bin) }

  it "picks apt when both apt-get and yum exist" do
    expect(detect_with("apt-get", "yum")).to eq(:apt)
  end

  it "picks yum without apt-get" do
    expect(detect_with("yum")).to eq(:yum)
  end

  it "reports unknown without either" do
    expect(detect_with).to eq(:unknown)
  end
end
