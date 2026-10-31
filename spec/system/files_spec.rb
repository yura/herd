# frozen_string_literal: true

require_relative "system_helper"

RSpec.describe Herd::Commands::Files, :system do
  def stat(s, path, format) = s.run("stat -c #{s.shell_args(format)} -- #{s.shell_path(path)}", pty: false).strip
  def mode_of(s, path) = stat(s, path, "%a")
  def leftovers(s, dir) = s.run("ls -A -- #{s.shell_path(dir)}", pty: false).split("\n").grep(/herd-/)
  def write(s, path, bytes) = s.run("cat > #{s.shell_path(path)}", pty: false, stdin: bytes)

  describe "#install_file" do
    it "creates a missing file with mode 644 and returns true" do
      with_system_session do |s, dir|
        expect(s.install_file("#{dir}/a.conf", "a = 1\n")).to be(true)
        expect([s.read_bytes("#{dir}/a.conf"), mode_of(s, "#{dir}/a.conf")]).to eq(["a = 1\n", "644"])
      end
    end

    it "creates a sensitive file with mode 600 and keeps its content out of the log" do
      with_system_session do |s, dir|
        s.install_file("#{dir}/a.conf", "password=hunter22\n", sensitive: true)

        expect(mode_of(s, "#{dir}/a.conf")).to eq("600")
        expect(File.read(Dir["log/**/*.jsonl"].fetch(0))).not_to include("hunter22")
      end
    end

    it "leaves identical content alone and returns false" do
      with_system_session do |s, dir|
        write(s, "#{dir}/a.conf", "a = 1\n")
        inode = stat(s, "#{dir}/a.conf", "%i")

        expect(s.install_file("#{dir}/a.conf", "a = 1\n")).to be(false)
        expect(stat(s, "#{dir}/a.conf", "%i")).to eq(inode)
      end
    end

    it "replaces different content with a new file, keeping the old mode and owner" do
      with_system_session do |s, dir|
        write(s, "#{dir}/a.conf", "a = 0\n")
        s.run("chmod 640 -- #{s.shell_path("#{dir}/a.conf")}")
        inode = stat(s, "#{dir}/a.conf", "%i")

        expect(s.install_file("#{dir}/a.conf", "a = 1\n", sudo: true)).to be(true)
        expect(s.read_bytes("#{dir}/a.conf")).to eq("a = 1\n")
        expect(stat(s, "#{dir}/a.conf", "%i")).not_to eq(inode)
        expect(stat(s, "#{dir}/a.conf", "%a %U")).to eq("640 herd")
        expect(leftovers(s, dir)).to be_empty
      end
    end

    it "sets the owner and mode given, before the file appears" do
      with_system_session do |s, dir|
        s.install_file("#{dir}/root.conf", "x\n", owner: "root", group: "root", mode: 600, sudo: true)

        expect(stat(s, "#{dir}/root.conf", "%U:%G %a")).to eq("root:root 600")
      end
    end

    it "keeps the existing group when only owner is given, and the owner when only group is" do
      with_system_session do |s, dir|
        write(s, "#{dir}/a.conf", "a\n")

        s.install_file("#{dir}/a.conf", "b\n", owner: "herd", sudo: true)
        expect(stat(s, "#{dir}/a.conf", "%U:%G")).to eq("herd:herd")

        s.install_file("#{dir}/a.conf", "c\n", group: "sudo", sudo: true)
        expect(stat(s, "#{dir}/a.conf", "%U:%G")).to eq("herd:sudo")
      end
    end

    it "keeps old and new content of a sensitive file out of the log when it is rewritten" do
      with_system_session do |s, dir|
        s.file("#{dir}/secret.conf", "herd", "herd", content: "token=old-#{"o" * 12}\n", mode: 600, sensitive: true)
        s.file("#{dir}/secret.conf", "herd", "herd", content: "token=new-#{"n" * 12}\n", mode: 600, sensitive: true)

        log = Dir["log/**/*.jsonl"].map { File.read(it) }.join
        ["old-#{"o" * 12}", "new-#{"n" * 12}"].each do |secret|
          expect(log).not_to include(secret, ["token=#{secret}\n"].pack("m0"))
        end
      end
    end

    it "fixes only the metadata when the content is unchanged" do
      with_system_session do |s, dir|
        write(s, "#{dir}/a.conf", "a = 1\n")

        expect(s.install_file("#{dir}/a.conf", "a = 1\n", mode: 600)).to be(false)
        expect(mode_of(s, "#{dir}/a.conf")).to eq("600")
      end
    end

    it "refuses to write through a symlink, leaving its target untouched" do
      with_system_session do |s, dir|
        write(s, "#{dir}/target", "keep\n")
        s.run("ln -s -- #{s.shell_path("#{dir}/target")} #{s.shell_path("#{dir}/link")}")

        expect { s.install_file("#{dir}/link", "x\n") }.to raise_error(Herd::Commands::Files::SymlinkError)
        expect(s.read_bytes("#{dir}/target")).to eq("keep\n")
      end
    end

    it "leaves the file untouched and removes the staged copy when validate fails" do
      with_system_session do |s, dir|
        write(s, "#{dir}/a.conf", "old\n")

        expect { s.install_file("#{dir}/a.conf", "new\n", validate: "grep -q valid %{staged}") }
          .to raise_error(Herd::CommandError)
        expect(s.read_bytes("#{dir}/a.conf")).to eq("old\n")
        expect(leftovers(s, dir)).to be_empty
      end
    end

    it "writes content literally: a heredoc delimiter and shell code are just bytes" do
      with_system_session do |s, dir|
        content = "a\nHERD_EOF\ntouch #{dir}/pwned\nHERD_SQL\n$(touch #{dir}/pwned)\n"

        s.install_file("#{dir}/a.conf", content)

        expect(s.read_bytes("#{dir}/a.conf")).to eq(content)
        expect(s.file_exists?("#{dir}/pwned")).to be(false)
      end
    end
  end

  describe "#write_to_file!" do
    it "uses sudo for a file the user owns in a directory it can't write to" do
      with_system_session do |s, _|
        path = "/etc/herd-spec-#{SecureRandom.hex(3)}.conf"
        s.install_file(path, "old\n", owner: "herd", sudo: true)

        expect(s.file_replaceable?(path)).to be(false)
        s.write_to_file!(path, "new", sudo: true)
        expect(s.read_bytes(path)).to eq("new\n")
        expect { s.write_to_file!(path, "x") }.to raise_error(Herd::Commands::Files::PermissionDeniedError)
      ensure
        s.sudo("rm -f -- #{path}") if path
      end
    end
  end

  describe "#with_upload" do
    it "removes the upload when the block leaves with break or return, or raises" do
      with_system_session do |s, _|
        paths = []
        [1].each { s.with_upload("x", sensitive: true) { |f| paths << f.path and break } }
        leave = ->(session) { session.with_upload("y") { |f| paths << f.path and return } }
        leave.call(s)
        begin
          s.with_upload("z") { |f| paths << f.path and raise "boom" }
        rescue RuntimeError
          nil
        end

        expect(paths.size).to eq(3)
        expect(paths.map { s.file_exists?(it) }).to eq([false, false, false])
        expect(s.send(:inside_sensitive_upload?)).to be(false)
      end
    end
  end

  describe "byte round trip" do
    ["", "no newline", "nul\0byte\n", "crlf\r\nline\r\n", "юникод ✓\n", "\xFF\xFEinvalid utf-8".b,
     "x" * 1_000_000].each do |content|
      it "writes and reads back #{content.bytesize} bytes exactly (#{content[0, 12].inspect})" do
        with_system_session do |s, dir|
          s.install_file("#{dir}/f", content)

          expect(s.read_bytes("#{dir}/f")).to eq(content.b)
          expect(s.read_bytes("#{dir}/f", sudo: true)).to eq(content.b)
        end
      end
    end
  end

  describe "#read_file" do
    it "removes one final line break of any kind, as chomp does, and keeps a leading newline under sudo" do
      with_system_session do |s, dir|
        { "a\n" => "a", "a\r\n" => "a", "a\r" => "a", "a\n\n" => "a\n", "\nfirst\n" => "\nfirst" }.each do |raw, want|
          write(s, "#{dir}/f", raw)

          expect([s.read_file("#{dir}/f"), s.read_file("#{dir}/f", sudo: true)]).to eq([want, want]), raw.inspect
        end
      end
    end
  end

  describe "#ensure_line_in_file" do
    it "matches whole lines, not a substring or a commented-out copy" do
      with_system_session do |s, dir|
        write(s, "#{dir}/f", "# a = 1\na = 10\n")

        expect(s.ensure_line_in_file("#{dir}/f", "a = 1")).to be(true)
        expect(s.ensure_line_in_file("#{dir}/f", "a = 1")).to be(false)
        expect(s.read_bytes("#{dir}/f")).to eq("# a = 1\na = 10\na = 1\n")
      end
    end

    it "creates a missing file, and starts a new line when the file doesn't end with one" do
      with_system_session do |s, dir|
        s.ensure_line_in_file("#{dir}/new", "a")
        write(s, "#{dir}/last", "last")
        s.ensure_line_in_file("#{dir}/last", "added")

        expect([s.read_bytes("#{dir}/new"), s.read_bytes("#{dir}/last")]).to eq(%W[a\n last\nadded\n])
      end
    end

    it "appends to a root-owned file with sudo: true, keeping the file" do
      with_system_session do |s, dir|
        s.install_file("#{dir}/root.conf", "a\n", owner: "root", mode: 644, sudo: true)
        inode = stat(s, "#{dir}/root.conf", "%i")
        s.ensure_line_in_file("#{dir}/root.conf", "b", sudo: true)

        expect(s.read_bytes("#{dir}/root.conf")).to eq("a\nb\n")
        expect(stat(s, "#{dir}/root.conf", "%i %U")).to eq("#{inode} root")
      end
    end
  end

  describe "#replace_line_in_file" do
    it "inserts the replacement literally, or what a block returns for each match" do
      with_system_session do |s, dir|
        write(s, "#{dir}/f", "port 22\nport 23\n")
        expect(s.replace_line_in_file("#{dir}/f", /^port (\d+)/, 'port \1 & $HOME')).to be(true)
        expect(s.read_bytes("#{dir}/f")).to eq("port \\1 & $HOME\nport \\1 & $HOME\n")

        write(s, "#{dir}/g", "port 22\n")
        s.replace_line_in_file("#{dir}/g", /^port (\d+)/) { |m| "port #{m[1].to_i + 1}" }
        expect(s.read_bytes("#{dir}/g")).to eq("port 23\n")
        expect(s.replace_line_in_file("#{dir}/g", /zzz/, "b")).to be(false)
      end
    end
  end

  describe "#prepend_to_file" do
    it "puts content first and keeps the mode" do
      with_system_session do |s, dir|
        write(s, "#{dir}/config", "Host x\n")
        s.run("chmod 600 -- #{s.shell_path("#{dir}/config")}")
        s.prepend_to_file("#{dir}/config", "Include ~/.ssh/config.d/*.conf")

        expect(s.read_bytes("#{dir}/config")).to eq("Include ~/.ssh/config.d/*.conf\nHost x\n")
        expect(mode_of(s, "#{dir}/config")).to eq("600")
      end
    end
  end
end
