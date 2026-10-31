# frozen_string_literal: true

require_relative "system_helper"

RSpec.describe Herd::Session, :system do
  describe "running commands" do
    it "runs a command over SSH" do
      expect(on_system_host { run("whoami").strip }).to eq("herd")
    end

    it "returns UTF-8 output; through the PTY line ends arrive as \\r\\n" do
      with_system_session do |s, _|
        expect(s.run("printf 'first\\nготово\\n'")).to eq("first\r\nготово\r\n")
        expect(s.run("printf 'first\\nготово\\n'", pty: false)).to eq("first\nготово\n")
        expect(s.run("printf x").encoding).to eq(Encoding::UTF_8)
      end
    end

    it "returns a failed command's status without raising, and raises from run" do
      with_system_session do |s, _|
        result = s.run_result("printf 'diagnostic'; exit 7")

        expect([result.output, result.exit_code]).to eq(["diagnostic", 7])
        expect { s.run("printf 'diagnostic'; exit 7") }.to raise_error(Herd::CommandError, ["diagnostic", 7].to_s)
      end
    end

    it "fails a pipeline whose first command fails (pipefail)" do
      with_system_session { |s, _| expect(s.run_result("false | true").exit_code).to eq(1) }
    end

    it "reports a missing command as 127" do
      with_system_session do |s, _|
        result = s.run_result("herd_no_such_command")
        expect([result.exit_code, result.output]).to match([127, /herd_no_such_command/])
      end
    end

    it "keeps stderr apart from stdout without a PTY" do
      with_system_session do |s, _|
        result = s.run_result("printf out; printf err >&2; exit 3", pty: false)
        expect([result.stdout, result.stderr, result.exit_code]).to eq(["out", "err", 3])
      end
    end

    it "sends stdin byte for byte, a heredoc delimiter included" do
      with_system_session do |s, _|
        input = "a\nHERD_EOF\n\0\xFF".b
        expect(s.run("od -An -tx1 | tr -d ' \\n'", pty: false, stdin: input)).to eq(input.unpack1("H*"))
      end
    end

    it "uses exit statuses, not output, in command_success?" do
      with_system_session do |s, _|
        expect(s.command_success?("printf no")).to be(true)
        expect(s.command_success?("printf yes; exit 1")).to be(false)
      end
    end
  end

  describe "within and with_env" do
    it "runs in the directory and environment, a path with spaces and $ included" do
      with_system_session do |s, dir|
        odd = "#{dir}/with space $HOME"
        s.run("mkdir -p -- #{s.shell_path(odd)}")

        out = s.within(odd) do
          s.with_env("HERD_VALUE" => "configured") do
            s.run('printf "%s:%s" "$PWD" "$HERD_VALUE"')
          end
        end
        expect(out).to eq("#{odd}:configured")
      end
    end
  end

  describe "within a directory that doesn't exist" do
    commands = {
      "after ;" => "true; touch MARK",
      "on the next line" => "true\ntouch MARK",
      "after a comment" => "true # cd failed?\ntouch MARK",
      "after ||" => "false || touch MARK",
      "in a subshell" => "(touch MARK)"
    }

    commands.each do |label, command|
      it "runs nothing, the command #{label} included" do
        with_system_session do |s, dir|
          marker = "#{dir}/marker"
          script = command.gsub("MARK", marker)

          expect { s.within("#{dir}/missing") { s.run(script) } }.to raise_error(Herd::CommandError, /missing/)
          expect(s.file_exists?(marker)).to be(false)
        end
      end
    end
  end

  describe "with_env when an export fails" do
    it "runs nothing" do
      with_system_session do |s, dir|
        # UID is read-only in bash: the name is valid, the export still fails.
        expect { s.with_env("UID" => "0") { s.run("touch #{dir}/marker") } }.to raise_error(Herd::CommandError, /readonly/)
        expect(s.file_exists?("#{dir}/marker")).to be(false)
      end
    end
  end

  describe "sudo" do
    it "answers the password prompt" do
      expect(on_system_host { sudo("whoami").strip }).to eq("root")
    end

    it "runs without a prompt for a NOPASSWD user" do
      expect(on_system_host(:nopass) { sudo("whoami").strip }).to eq("root")
    end

    it "raises on a wrong password instead of answering again" do
      # The password changes after SSH login; -k makes sudo ask for it.
      expect { on_system_host { host.password = "wrong" and sudo("-k whoami") } }
        .to raise_error(Herd::CommandError, "sudo: authentication failed")
    end
  end

  describe "timeout" do
    it "raises CommandTimeout and leaves the session usable" do
      with_system_session do |s, _|
        expect { s.run("sleep 5", timeout: 0.5) }.to raise_error(Herd::CommandTimeout)
        expect(s.run("printf ok")).to eq("ok")
      end
    end
  end

  describe "a remote shell killed by a signal" do
    it "is an unknown outcome, not an ordinary failure, and leaves the session usable" do
      with_system_session do |s, _|
        expect { s.run("kill -9 $$") }.to raise_error(Herd::CommandOutcomeUnknown, /without exit status/)
        expect(s.run("printf ok")).to eq("ok")
      end
    end
  end

  describe "file predicates" do
    it "tests existing and missing paths, and tells a broken symlink from its target" do
      with_system_session do |s, dir|
        path = "#{dir}/file with 'quotes' $literal"
        s.install_file(path, "yes\n")
        s.run("ln -s missing-target #{s.shell_path("#{dir}/broken link")}")

        expect([s.file_exists?(path), s.file_readable?(path), s.file_writable?(path)]).to eq([true, true, true])
        expect(s.file_exists?("#{path}.missing")).to be(false)
        expect([s.symlink?("#{dir}/broken link"), s.file_exists?("#{dir}/broken link")]).to eq([true, false])
      end
    end
  end
end
