# frozen_string_literal: true

require "open3"
require "tmpdir"

# File commands run through a real shell, with HOME at a scratch dir and
# a path full of characters the shell would otherwise split or expand.
RSpec.describe Herd::Commands::Files do
  let(:session) { Herd::Session.new(nil, nil, nil, nil) }
  let(:home) { Dir.mktmpdir }
  let(:dir) { %(~/dir with 'q' "dq" $HOME) }
  let(:path) { "#{dir}/file name" }
  let(:local_path) { File.join(home, %(dir with 'q' "dq" $HOME), "file name") }

  before do
    allow(session).to receive(:run_result) do |cmd|
      out, status = Open3.capture2e({ "HOME" => home }, "bash", "-c", "set -o pipefail; #{cmd}")
      Herd::CommandResult.new(output: out, exit_code: status.exitstatus)
    end
    allow(session).to receive(:sudo) { |cmd| session.run(cmd) }
  end

  after { FileUtils.remove_entry(home) }

  describe "#shell_path" do
    it "expands ~ to the remote home and keeps the rest literal" do
      expect(session.shell_path("~")).to eq('"$HOME"')
      expect(session.shell_path("~/a b")).to eq('"$HOME"/a\ b')
      expect(session.shell_path("/etc/x$y")).to eq('/etc/x\$y')
      expect(session.shell_path("~user/x")).to eq('\~user/x')
    end
  end

  it "creates, writes, reads and appends at a hostile path under ~" do
    session.mkdir_p(dir, nil, nil)
    session.write_to_file(path, "one\nEOF\n")
    session.append_to_file(path, "two")
    session.ensure_line_in_file(path, "three")
    session.ensure_line_in_file(path, "three")

    expect(File.read(local_path)).to eq("one\nEOF\ntwo\nthree\n")
    expect(session.file_exists?(path)).to be(true)
    expect(session.read_file(path)).to eq("one\nEOF\ntwo\nthree")
    expect(session.file_contains?(path, "EOF")).to be(true)
  end

  it "reports changes through expect_file_content_equals at that path" do
    session.mkdir_p(dir, nil, nil)

    expect(session.expect_file_content_equals(path, "a\n")).to be(true)
    expect(session.expect_file_content_equals(path, "a\n")).to be(false)
  end

  it "doesn't touch look-alike files the unescaped path would have hit" do
    session.mkdir_p(dir, nil, nil)
    decoy = File.join(home, "dir")
    File.write(decoy, "keep")

    session.file_permissions(path, 600) if session.write_to_file(path, "x")

    expect(File.read(decoy)).to eq("keep")
    expect(format("%o", File.stat(local_path).mode & 0o777)).to eq("600")
  end

  describe "#glob" do
    def touch(name) = File.write(File.join(home, name), "")
    def names(pattern, **) = session.glob(pattern, **).map { File.basename(_1) }

    it "returns matching paths sorted, with spaces and newlines in names intact" do
      ["b.log", "a.log", "x.txt", "with space.log", "line\nbreak.log"].each { touch(_1) }

      expect(names("~/*.log")).to eq(["a.log", "b.log", "line\nbreak.log", "with space.log"])
    end

    it "returns [] when nothing matches" do
      expect(session.glob("~/*.nope")).to eq([])
    end

    it "returns [] for a plain path that doesn't exist, and the path when it does" do
      touch("plain")

      expect(session.glob("~/missing")).to eq([])
      expect(names("~/plain")).to eq(["plain"])
    end

    it "keeps a dangling symlink, since the link itself exists" do
      File.symlink("/nonexistent", File.join(home, "dangling"))
      expect(names("~/dang*")).to eq(["dangling"])
    end

    it "supports ? and [...] and keeps the rest literal" do
      %w[a1 a2 b1 $x].each { touch(_1) }

      expect(names("~/a?")).to eq(%w[a1 a2])
      expect(names("~/[ab]1")).to eq(%w[a1 b1])
      expect(names("~/$x")).to eq(["$x"])
    end

    it "never runs shell code from the pattern" do
      marker = File.join(home, "pwned")

      ["~/$(touch #{marker})*", "~/`touch #{marker}`*", "~/*; touch #{marker}", "~/[$(touch #{marker})]"]
        .each { session.glob(_1) }

      expect(File.exist?(marker)).to be(false)
    end

    it "resolves ~ to the SSH user even under sudo" do
      touch("mine.conf")
      expect(names("~/*.conf", sudo: true)).to eq(["mine.conf"])
    end
  end
end
