# frozen_string_literal: true

RSpec.describe Herd::Commands::Apt do
  let(:session) { Herd::Session.new(nil, nil, "secret", log) }
  let(:output) { +"" }
  let(:log) { StringIO.new }

  before do
    allow(session).to receive(:run_result) { Herd::CommandResult.new(stdout: output, exit_code: 0) }
  end

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#apt_update" do
    it "runs apt update" do
      session.apt_update
      expect(session).to have_received(:run_result).with("sudo -p 'HERD_SUDO: ' apt update -qq", sudo_prompt: true)
    end
  end

  describe "#apt_upgrade" do
    it "runs apt upgrade non-interactively" do
      session.apt_upgrade
      expect(session).to have_received(:run_result).with(
        "sudo -p 'HERD_SUDO: ' DEBIAN_FRONTEND=noninteractive apt upgrade -qq -y", sudo_prompt: true
      )
    end
  end

  describe "#apt_install" do
    it "installs a single package" do
      session.apt_install("curl")
      expect(session).to have_received(:run_result).with(
        "sudo -p 'HERD_SUDO: ' DEBIAN_FRONTEND=noninteractive apt install -qq -y curl", sudo_prompt: true
      )
    end

    it "installs multiple packages" do
      session.apt_install("curl", "git", "vim")
      expect(session).to have_received(:run_result).with(
        "sudo -p 'HERD_SUDO: ' DEBIAN_FRONTEND=noninteractive apt install -qq -y curl git vim", sudo_prompt: true
      )
    end

    it "accepts an array of packages" do
      session.apt_install(%w[curl git])
      expect(session).to have_received(:run_result).with(
        "sudo -p 'HERD_SUDO: ' DEBIAN_FRONTEND=noninteractive apt install -qq -y curl git", sudo_prompt: true
      )
    end

    it "adds --force-confnew when confnew: true" do
      session.apt_install("postgresql-16", confnew: true)
      expect(session).to have_received(:run_result).with(
        "sudo -p 'HERD_SUDO: ' DEBIAN_FRONTEND=noninteractive apt install -qq -y -o Dpkg::Options::\\=--force-confnew postgresql-16", sudo_prompt: true
      )
    end
  end

  describe "#apt_remove" do
    it "removes packages" do
      session.apt_remove("curl")
      expect(session).to have_received(:run_result).with("sudo -p 'HERD_SUDO: ' apt remove -qq -y curl",
                                                         sudo_prompt: true)
    end
  end

  describe "#apt_autoremove" do
    it "runs apt autoremove" do
      session.apt_autoremove
      expect(session).to have_received(:run_result).with("sudo -p 'HERD_SUDO: ' apt autoremove -qq -y",
                                                         sudo_prompt: true)
    end
  end

  describe "package names" do
    it "refuses names that aren't package names before running anything" do
      ["-o APT::x", "curl; rm -rf /", "a b", ""].each do |name|
        expect { session.apt_install(name) }.to raise_error(ArgumentError)
      end
      expect(session).not_to have_received(:run_result)
    end

    it "accepts versions, architectures and releases" do
      session.apt_install("nginx=1.24.0-1", "libc6:amd64", "git/noble-backports")

      expect(session).to have_received(:run_result)
        .with(a_string_ending_with("apt install -qq -y nginx\\=1.24.0-1 libc6:amd64 git/noble-backports"), sudo_prompt: true)
    end
  end

  describe "local .deb files" do
    it "passes paths to apt_install as paths, escaped, ~ as the SSH user's home" do
      session.apt_install("/tmp/my pkg.deb", "./x.deb", "~/debs/y.deb", "curl")

      expect(session).to have_received(:run_result).with(
        "sudo -p 'HERD_SUDO: ' DEBIAN_FRONTEND=noninteractive apt install -qq -y " \
        "/tmp/my\\ pkg.deb ./x.deb \"$HOME\"/debs/y.deb curl", sudo_prompt: true
      )
    end

    it "keeps refusing paths where only package names make sense" do
      expect { session.apt_remove("/tmp/x.deb") }.to raise_error(ArgumentError)
      expect { session.apt_install("x.deb; rm -rf /") }.to raise_error(ArgumentError)
    end
  end

  describe "#apt_installed? and #apt_version" do
    def dpkg(status, version: "7.81.0-1ubuntu1.20", exit_code: 0)
      allow(session).to receive(:run_result) do |command, **|
        out = command.include?("Status") ? status : version
        Herd::CommandResult.new(stdout: out, stderr: exit_code == 1 ? "no packages found" : "", exit_code: exit_code)
      end
    end

    it "reports an installed package and its version" do
      dpkg("install ok installed")

      expect([session.apt_installed?("curl"), session.apt_version("curl")]).to eq([true, "7.81.0-1ubuntu1.20"])
    end

    it "doesn't count a removed package whose config files remain" do
      dpkg("deinstall ok config-files")

      expect([session.apt_installed?("curl"), session.apt_version("curl")]).to eq([false, nil])
    end

    it "returns false and nil for a package dpkg doesn't know" do
      dpkg("", exit_code: 1)

      expect([session.apt_installed?("curl"), session.apt_version("curl")]).to eq([false, nil])
    end

    it "raises when dpkg-query itself fails" do
      dpkg("", exit_code: 2)

      expect { session.apt_installed?("curl") }.to raise_error(Herd::CommandError)
    end
  end
end
