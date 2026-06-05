# frozen_string_literal: true

RSpec.describe Herd::Commands::Apt do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil) }

  before do
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)
    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:on_extended_data)
    allow(mock_ssh_channel).to receive(:on_request).with("exit-status")
      .and_yield(nil, instance_double(Net::SSH::Buffer, read_long: 0))
  end

  def stub_command(cmd)
    allow(mock_ssh_channel).to receive(:exec)
      .with("set -o pipefail; #{cmd}")
      .and_yield(mock_ssh_channel, nil)
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "")
  end

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#apt_update" do
    it "runs apt update" do
      stub_command("sudo apt update -qq")
      session.apt_update
      expect(mock_ssh_channel).to have_received(:exec).with("set -o pipefail; sudo apt update -qq")
    end
  end

  describe "#apt_upgrade" do
    it "runs apt upgrade non-interactively" do
      stub_command("sudo DEBIAN_FRONTEND=noninteractive apt upgrade -qq -y")
      session.apt_upgrade
      expect(mock_ssh_channel).to have_received(:exec)
        .with("set -o pipefail; sudo DEBIAN_FRONTEND=noninteractive apt upgrade -qq -y")
    end
  end

  describe "#apt_install" do
    it "installs a single package" do
      stub_command("sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y curl")
      session.apt_install("curl")
      expect(mock_ssh_channel).to have_received(:exec)
        .with("set -o pipefail; sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y curl")
    end

    it "installs multiple packages" do
      stub_command("sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y curl git vim")
      session.apt_install("curl", "git", "vim")
      expect(mock_ssh_channel).to have_received(:exec)
        .with("set -o pipefail; sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y curl git vim")
    end

    it "accepts an array of packages" do
      stub_command("sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y curl git")
      session.apt_install(%w[curl git])
      expect(mock_ssh_channel).to have_received(:exec)
        .with("set -o pipefail; sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y curl git")
    end

    it "adds --force-confnew when confnew: true" do
      stub_command("sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y -o Dpkg::Options::='--force-confnew' postgresql-16")
      session.apt_install("postgresql-16", confnew: true)
      expect(mock_ssh_channel).to have_received(:exec)
        .with("set -o pipefail; sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y -o Dpkg::Options::='--force-confnew' postgresql-16")
    end
  end

  describe "#apt_remove" do
    it "removes packages" do
      stub_command("sudo apt remove -qq -y curl")
      session.apt_remove("curl")
      expect(mock_ssh_channel).to have_received(:exec)
        .with("set -o pipefail; sudo apt remove -qq -y curl")
    end
  end

  describe "#apt_autoremove" do
    it "runs apt autoremove" do
      stub_command("sudo apt autoremove -qq -y")
      session.apt_autoremove
      expect(mock_ssh_channel).to have_received(:exec).with("set -o pipefail; sudo apt autoremove -qq -y")
    end
  end

  describe "#apt_installed?" do
    let(:check_cmd) { "set -o pipefail; dpkg -l curl 2>/dev/null | grep -q '^ii' && echo yes || echo no" }

    before do
      allow(mock_ssh_channel).to receive(:exec).with(check_cmd).and_yield(mock_ssh_channel, nil)
    end

    it "returns true when package is installed" do
      allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "yes")
      expect(session.apt_installed?("curl")).to be true
    end

    it "returns false when package is not installed" do
      allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "no")
      expect(session.apt_installed?("curl")).to be false
    end
  end
end
