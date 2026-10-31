# frozen_string_literal: true

RSpec.describe "commands ported from footbot recipes" do # rubocop:disable RSpec/DescribeClass
  let(:session) { Herd::Session.new(nil, nil, nil, nil) }

  # Shell behaviour of ssh_set_permissions and ensure_symlink is in spec/system/commands_spec.rb.
  before { allow(session).to receive(:info) }

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
      allow(session).to receive(:run_result).with("localectl status", pty: false)
                                            .and_return(Herd::CommandResult.new(stdout: localectl, exit_code: 0))
    end

    let(:localectl) { "   System Locale: LANG=en_US.UTF-8\n       VC Keymap: n/a\n" }

    it "skips when localectl and /etc/default/locale agree" do
      allow(session).to receive(:read_file!).and_return("LANG=en_US.UTF-8\n")

      expect(session.set_locale("en_US.UTF-8")).to be(false)
      expect(session).not_to have_received(:sudo)
    end

    it "sets both when /etc/default/locale has extra lines" do
      allow(session).to receive(:read_file!).and_return("LANG=en_US.UTF-8\nLANGUAGE=en")

      expect(session.set_locale("en_US.UTF-8")).to be(true)
      expect(session).to have_received(:sudo).with("localectl set-locale LANG\\=en_US.UTF-8")
      expect(session).to have_received(:expect_file_content_equals).with("/etc/default/locale", "LANG=en_US.UTF-8\n")
    end

    it "sets the locale when localectl can't report it" do
      allow(session).to receive(:run_result).with("localectl status", pty: false)
                                            .and_return(Herd::CommandResult.new(stdout: "", exit_code: 1))
      allow(session).to receive(:read_file!).and_return("LANG=en_US.UTF-8\n")

      expect(session.set_locale("en_US.UTF-8")).to be(true)
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
      %i[apt_update apt_install git_repo ensure_line_in_file].each { allow(session).to receive(it) }

      session.rbenv_install

      expect(session).to have_received(:apt_install).with(Herd::Commands::Ruby::RUBY_BUILD_APT_DEPS)
      expect(session).to have_received(:git_repo).with("~/.rbenv/plugins/ruby-build", anything, ref: "master")
    end

    it "skips build deps with build_deps: false" do
      %i[apt_install git_repo ensure_line_in_file].each { allow(session).to receive(it) }

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
