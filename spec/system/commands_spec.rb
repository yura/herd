# frozen_string_literal: true

require_relative "system_helper"

# Commands whose correctness is what the remote shell does with the composed command:
# quoting of hostile paths, globbing, symlinks, permissions, users.
RSpec.describe "Herd commands in a real shell", :system do
  def write(s, path, bytes) = s.run("cat > #{s.shell_path(path)}", pty: false, stdin: bytes)
  def mode_of(s, path) = s.run("stat -c %a -- #{s.shell_path(path)}", pty: false).strip
  def readlink(s, path) = s.run("readlink -- #{s.shell_path(path)}", pty: false).strip

  describe "paths full of shell syntax" do
    # "~/..." goes through "$HOME" in the remote shell, so the scratch dir lives under ~.
    let(:odd) { %(herd-spec dir 'q' "dq" $HOME) }

    it "creates, writes, reads and appends under ~ without touching look-alike paths" do
      with_system_session do |s, _|
        dir  = "~/#{odd}-#{SecureRandom.hex(4)}"
        path = "#{dir}/file name"
        s.mkdir_p(dir, nil, nil)
        write(s, s.run("printf %s ~", pty: false) + "/herd-spec", "keep") # a look-alike of the first word

        s.write_to_file(path, "one\nEOF\n")
        s.append_to_file(path, "two")
        s.ensure_line_in_file(path, "three")
        s.ensure_line_in_file(path, "three")
        s.file_permissions(path, 600)

        expect(s.read_file(path)).to eq("one\nEOF\ntwo\nthree")
        expect(s.file_contains?(path, "EOF")).to be(true)
        expect(mode_of(s, path)).to eq("600")
        expect(s.read_bytes("~/herd-spec")).to eq("keep")
        expect(s.expect_file_content_equals(path, "one\nEOF\ntwo\nthree\n")).to be(false)
      ensure
        s.run("rm -rf -- #{s.shell_path(dir)} ~/herd-spec", pty: false)
      end
    end
  end

  describe "#glob" do
    def names(s, pattern, **) = s.glob(pattern, **).map { File.basename(it) }

    it "returns matching paths sorted, with spaces and newlines in names intact" do
      with_system_session do |s, dir|
        ["b.log", "a.log", "x.txt", "with space.log", "line\nbreak.log"].each { write(s, "#{dir}/#{it}", "") }

        expect(names(s, "#{dir}/*.log")).to eq(["a.log", "b.log", "line\nbreak.log", "with space.log"])
        expect(s.glob("#{dir}/*.nope")).to eq([])
      end
    end

    it "returns a plain path only when it exists, and keeps a dangling symlink" do
      with_system_session do |s, dir|
        write(s, "#{dir}/plain", "")
        s.run("ln -s /nonexistent #{s.shell_path("#{dir}/dangling")}")

        expect(s.glob("#{dir}/missing")).to eq([])
        expect(names(s, "#{dir}/plain")).to eq(["plain"])
        expect(names(s, "#{dir}/dang*")).to eq(["dangling"])
      end
    end

    it "supports ? and [...], keeps the rest literal and never runs shell code from the pattern" do
      with_system_session do |s, dir|
        %w[a1 a2 b1 $x].each { write(s, "#{dir}/#{it}", "") }
        marker = "#{dir}/pwned"

        expect(names(s, "#{dir}/a?")).to eq(%w[a1 a2])
        expect(names(s, "#{dir}/[ab]1")).to eq(%w[a1 b1])
        expect(names(s, "#{dir}/$x")).to eq(["$x"])
        ["#{dir}/$(touch #{marker})*", "#{dir}/`touch #{marker}`*", "#{dir}/*; touch #{marker}",
         "#{dir}/[$(touch #{marker})]"].each { s.glob(it) }
        expect(s.file_exists?(marker)).to be(false)
      end
    end

    it "resolves ~ to the SSH user even under sudo" do
      with_system_session do |s, _|
        write(s, "~/herd-glob.conf", "")

        expect(names(s, "~/herd-glob*.conf", sudo: true)).to eq(["herd-glob.conf"])
      ensure
        s.run("rm -f ~/herd-glob.conf", pty: false)
      end
    end
  end

  describe "#ensure_symlink" do
    it "creates a missing link, leaves a correct one, repoints a stale one" do
      with_system_session do |s, dir|
        link = "#{dir}/link name"
        expect(s.ensure_symlink(link, "/etc/hosts")).to be(true)
        expect(s.ensure_symlink(link, "/etc/hosts")).to be(false)
        expect(s.ensure_symlink(link, "/etc/passwd")).to be(true)
        expect(readlink(s, link)).to eq("/etc/passwd")
      end
    end

    it "refuses to replace a real directory" do
      with_system_session do |s, dir|
        s.run("mkdir -- #{s.shell_path("#{dir}/real")}")

        expect { s.ensure_symlink("#{dir}/real", "/etc/hosts") }.to raise_error(Herd::CommandError)
      end
    end

    it "resolves ~/ in link and target, so a correct link isn't recreated" do
      with_system_session do |s, _|
        s.run("mkdir -p ~/herd-target", pty: false)

        expect(s.ensure_symlink("~/herd-lnk", "~/herd-target")).to be(true)
        expect(s.ensure_symlink("~/herd-lnk", "~/herd-target")).to be(false)
      ensure
        s.run("rm -rf ~/herd-lnk ~/herd-target", pty: false)
      end
    end
  end

  describe "#ssh_set_permissions" do
    it "fixes the dirs ssh_deploy_key creates and the private files inside them" do
      with_system_session(:nopass) do |s, _|
        s.run("mkdir -p -m 755 ~/.ssh/deploy_keys ~/.ssh/config.d && " \
              "touch ~/.ssh/deploy_keys/app_ed25519 ~/.ssh/deploy_keys/app_ed25519.pub ~/.ssh/config.d/app.conf && " \
              "chmod 644 ~/.ssh/deploy_keys/* ~/.ssh/config.d/*", pty: false)

        s.ssh_set_permissions

        expect(%w[~/.ssh ~/.ssh/deploy_keys ~/.ssh/config.d].map { mode_of(s, it) }).to eq(%w[700 700 700])
        expect(%w[app_ed25519 app_ed25519.pub].map { mode_of(s, "~/.ssh/deploy_keys/#{it}") }).to eq(%w[600 644])
        expect(mode_of(s, "~/.ssh/config.d/app.conf")).to eq("600")
      ensure
        s.run("rm -rf ~/.ssh/deploy_keys ~/.ssh/config.d", pty: false)
      end
    end

    it "raises when chmod fails instead of hiding it" do
      with_system_session(:nopass) do |s, _|
        dir = s.shell_path("~/.ssh/deploy_keys")
        s.sudo("sh -c #{"mkdir -p -- \"$1\" && chown root:root -- \"$1\"".shellescape} _ #{dir}")

        expect { s.ssh_set_permissions }.to raise_error(Herd::CommandError, /Operation not permitted/)
      ensure
        s.sudo("rm -rf ~/.ssh/deploy_keys")
      end
    end
  end

  describe "authorized keys" do
    it "appends keys and makes the file private, then reads them back" do
      with_system_session(:nopass) do |s, _|
        s.run("mkdir -p ~/.ssh && rm -f ~/.ssh/authorized_keys", pty: false)
        s.add_authorized_key("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC")
        s.add_authorized_key("ssh-ed25519 second")

        expect(s.authorized_keys).to eq(["ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC", "ssh-ed25519 second"])
        expect(mode_of(s, "~/.ssh/authorized_keys")).to eq("600")
      ensure
        s.run("rm -f ~/.ssh/authorized_keys", pty: false)
      end
    end
  end

  describe "users" do
    it "tells existing users from missing ones" do
      with_system_session do |s, _|
        expect([s.user_exists?("herd"), s.user_exists?("herd_no_such_user")]).to eq([true, false])
      end
    end

    it "sets a password with spaces, quotes and $() literally and keeps it out of the log" do
      password = %(alpha beta $(echo pwned) 'q" \\ end)
      with_system_session do |s, _|
        user = "herdpw#{SecureRandom.hex(3)}"
        s.user_create(user)
        s.change_password(user, password)

        # Logging in over SSH with exactly that password proves chpasswd got it unchanged.
        login = Herd::Host.new(system_host.host, system_host.explicit_ssh_options.merge(user: user, password: password))
        expect(login.exec { run("whoami").strip }).to eq(user)
        expect(Dir["log/**/*.jsonl"].map { File.read(it) }.join).not_to include("alpha beta")
      ensure
        s.sudo("userdel -r #{user}") if user
      end
    end
  end

  describe "package manager detection" do
    # package_manager is remembered per session, so each case gets its own.
    def detect(path = nil)
      with_system_session do |s, dir|
        s.run("printf '#!/bin/sh\\n' > #{s.shell_path("#{dir}/yum")} && chmod 755 #{s.shell_path("#{dir}/yum")}")
        if path
          s.with_env("PATH" => path.gsub("DIR", dir.shellescape)) do
            s.send(:package_manager)
          end
        else
          s.send(:package_manager)
        end
      end
    end

    it "picks apt on Ubuntu, and yum or unknown by what PATH offers" do
      expect([detect, detect("DIR"), detect("/nonexistent")]).to eq(%i[apt yum unknown])
    end
  end
end
