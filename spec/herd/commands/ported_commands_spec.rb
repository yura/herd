# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "commands ported from footbot recipes" do # rubocop:disable RSpec/DescribeClass
  let(:session) { Herd::Session.new(nil, nil, nil, nil) }
  let(:home) { Dir.mktmpdir }

  before { allow(session).to receive(:info) }
  after { FileUtils.remove_entry(home) }

  # Runs commands in a real shell with HOME pointed at a scratch dir.
  def run_locally(env = {})
    allow(session).to receive(:run) do |cmd|
      out, status = Open3.capture2e({ "HOME" => home }.merge(env), "bash", "-c", cmd)
      raise Herd::CommandError, out unless status.success?

      out
    end
  end

  def mode(path) = format("%o", File.stat(File.join(home, path)).mode & 0o777)

  describe "#ssh_set_permissions" do
    it "fixes the dirs ssh_deploy_key creates and the private files inside them" do
      %w[.ssh/deploy_keys .ssh/config.d].each { |dir| FileUtils.mkdir_p(File.join(home, dir), mode: 0o755) }
      %w[.ssh/deploy_keys/app_ed25519 .ssh/deploy_keys/app_ed25519.pub .ssh/config.d/app.conf].each do |file|
        File.write(File.join(home, file), "x")
        File.chmod(0o644, File.join(home, file))
      end
      run_locally
      allow(session).to receive(:file_exists?).and_return(false)
      allow(session).to receive(:ssh_chmod)

      session.ssh_set_permissions

      expect(%w[.ssh/deploy_keys .ssh/config.d].map { mode(_1) }).to eq(%w[700 700])
      expect(mode(".ssh/deploy_keys/app_ed25519")).to eq("600")
      expect(mode(".ssh/config.d/app.conf")).to eq("600")
      expect(mode(".ssh/deploy_keys/app_ed25519.pub")).to eq("644")
    end

    it "raises when chmod fails instead of hiding it" do
      FileUtils.mkdir_p(File.join(home, ".ssh/deploy_keys"))
      bin = File.join(home, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "chmod"), "#!/bin/sh\necho denied >&2\nexit 1\n")
      File.chmod(0o755, File.join(bin, "chmod"))
      run_locally("PATH" => "#{bin}:#{ENV.fetch("PATH")}")

      expect { session.send(:ssh_herd_dirs_permissions) }.to raise_error(Herd::CommandError, /denied/)
    end

    it "skips dirs that don't exist" do
      run_locally
      expect { session.send(:ssh_herd_dirs_permissions) }.not_to raise_error
    end
  end

  describe "#ensure_symlink" do
    before { run_locally }

    let(:link) { File.join(home, "link") }

    it "creates a missing link, then leaves a correct one alone" do
      expect(session.ensure_symlink(link, "/etc/hosts")).to be(true)
      expect(session.ensure_symlink(link, "/etc/hosts")).to be(false)
      expect(File.readlink(link)).to eq("/etc/hosts")
    end

    it "repoints a stale link" do
      File.symlink("/etc/old", link)

      expect(session.ensure_symlink(link, "/etc/hosts")).to be(true)
      expect(File.readlink(link)).to eq("/etc/hosts")
    end

    it "refuses to replace a real directory" do
      Dir.mkdir(link)
      expect { session.ensure_symlink(link, "/etc/hosts") }.to raise_error(Herd::CommandError)
    end

    it "treats a path with spaces as one path, leaving look-alike files alone" do
      %w[link name].each { |f| File.write(File.join(home, f), "keep") }

      session.ensure_symlink(File.join(home, "link name"), "/etc/hosts")

      expect(File.readlink(File.join(home, "link name"))).to eq("/etc/hosts")
      expect(%w[link name].map { File.read(File.join(home, _1)) }).to eq(%w[keep keep])
    end

    it "resolves ~/ in link and target, so a correct link isn't recreated" do
      FileUtils.mkdir_p(File.join(home, "some-project"))

      expect(session.ensure_symlink("~/lnk", "~/some-project")).to be(true)
      expect(session.ensure_symlink("~/lnk", "~/some-project")).to be(false)
      expect(File.readlink(File.join(home, "lnk"))).to eq(File.join(home, "some-project"))
    end
  end

  describe "#locale_generate" do
    before { allow(session).to receive(:sudo) }

    it "matches locale -a's normalized names" do
      allow(session).to receive(:run).and_return("C\nC.utf8\nen_US.utf8\n")

      expect(session.locale_generate("en_US.UTF-8")).to be(false)
      expect(session).not_to have_received(:sudo)
    end

    it "generates a missing locale" do
      allow(session).to receive(:run).and_return("C\n")

      expect(session.locale_generate("ru_RU.UTF-8")).to be(true)
      expect(session).to have_received(:sudo).with("locale-gen ru_RU.UTF-8")
    end
  end

  describe "#set_locale" do
    before do
      allow(session).to receive(:sudo)
      allow(session).to receive(:expect_file_content_equals)
      allow(session).to receive(:file_exists?).with("/etc/default/locale").and_return(true)
    end

    it "skips when localectl and /etc/default/locale agree" do
      allow(session).to receive_messages(run: "System Locale: LANG=en_US.UTF-8", read_file!: "LANG=en_US.UTF-8\n")

      expect(session.set_locale("en_US.UTF-8")).to be(false)
      expect(session).not_to have_received(:sudo)
    end

    it "sets both when /etc/default/locale has extra lines" do
      allow(session).to receive_messages(run: "System Locale: LANG=en_US.UTF-8",
                                         read_file!: "LANG=en_US.UTF-8\nLANGUAGE=en")

      expect(session.set_locale("en_US.UTF-8")).to be(true)
      expect(session).to have_received(:sudo).with("localectl set-locale LANG=en_US.UTF-8")
      expect(session).to have_received(:expect_file_content_equals).with("/etc/default/locale", "LANG=en_US.UTF-8\n")
    end
  end

  describe "#set_timezone" do
    before { allow(session).to receive(:sudo) }

    it "changes only a different timezone" do
      allow(session).to receive(:system_timezone).and_return("UTC")

      expect(session.set_timezone("UTC")).to be(false)
      expect(session.set_timezone("Europe/Paris")).to be(true)
      expect(session).to have_received(:sudo).with("timedatectl set-timezone Europe/Paris").once
    end
  end

  describe "rbenv" do
    before { allow(session).to receive(:run).and_return("") }

    it "installs build deps only on a fresh rbenv, then rbenv and ruby-build" do
      allow(session).to receive(:file_exists?).and_return(false)
      %i[apt_update apt_install git_repo ensure_line_in_file].each { allow(session).to receive(_1) }

      session.rbenv_install

      expect(session).to have_received(:apt_install).with(Herd::Commands::Ruby::RUBY_BUILD_APT_DEPS)
      expect(session).to have_received(:git_repo).with("~/.rbenv/plugins/ruby-build", anything, ref: "master")
    end

    it "skips build deps with build_deps: false" do
      %i[apt_install git_repo ensure_line_in_file].each { allow(session).to receive(_1) }

      session.rbenv_install(build_deps: false)
      expect(session).not_to have_received(:apt_install)
    end

    it "builds a missing ruby and sets the global only when it differs" do
      allow(session).to receive(:run).with("~/.rbenv/bin/rbenv versions --bare").and_return("3.3.0\n")
      allow(session).to receive(:run).with("~/.rbenv/bin/rbenv global").and_return("3.4.2\n")

      expect(session.rbenv_install_ruby("3.4.2")).to be(true)
      expect(session.rbenv_install_ruby("3.3.0")).to be(false)
      expect(session.rbenv_global("3.4.2")).to be(false)
      expect(session.rbenv_global("3.3.0")).to be(true)
    end
  end

  describe "#authorized_keys_sync" do
    let(:header) { Herd::MANAGED_HEADER }

    before do
      allow(session).to receive(:authorized_keys=)
      allow(session).to receive(:ssh_set_permissions)
    end

    it "refuses unknown keys unless told to remove them" do
      allow(session).to receive(:authorized_keys).and_return(["ssh-ed25519 AAA stranger"])

      expect { session.authorized_keys_sync(["ssh-ed25519 BBB me"]) }.to raise_error(Herd::CommandError, /stranger/)
      expect(session.authorized_keys_sync(["ssh-ed25519 BBB me"], remove_unknown: true)).to be(true)
      expect(session).to have_received(:authorized_keys=).with([header, "ssh-ed25519 BBB me"])
    end

    it "leaves an up-to-date file alone" do
      allow(session).to receive(:authorized_keys).and_return([header, "ssh-ed25519 BBB me"])

      expect(session.authorized_keys_sync(["ssh-ed25519 BBB me"])).to be(false)
      expect(session).not_to have_received(:authorized_keys=)
      expect(session).to have_received(:ssh_set_permissions)
    end
  end
end
