# frozen_string_literal: true

RSpec.describe Herd::Commands::OsRelease do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  let(:os_release_output) do
    <<~OS_RELEASE
      PRETTY_NAME="Ubuntu 24.04.1 LTS"
      NAME="Ubuntu"
      VERSION_ID="24.04"
      VERSION="24.04.1 LTS (Noble Numbat)"
      ID=ubuntu
      ID_LIKE=debian
      VERSION_CODENAME=noble
    OS_RELEASE
  end

  before do
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)
    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:on_extended_data)
    allow(mock_ssh_channel).to receive(:on_request).with("exit-status")
                                                   .and_yield(nil, instance_double(Net::SSH::Buffer, read_long: 0))
    allow(mock_ssh_channel).to receive(:exec)
      .with("set -o pipefail; cat /etc/os-release")
      .and_yield(mock_ssh_channel, nil)
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, os_release_output)
  end

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#os_release" do
    it "parses key/value pairs, stripping surrounding quotes" do
      expect(session.os_release).to include(
        "ID" => "ubuntu",
        "VERSION_ID" => "24.04",
        "VERSION_CODENAME" => "noble",
        "PRETTY_NAME" => "Ubuntu 24.04.1 LTS"
      )
    end

    it "only fetches the file once per session" do
      session.os_release
      session.os_release

      expect(mock_ssh_channel).to have_received(:exec).once
    end
  end

  describe "#refresh_os_release" do
    let(:upgraded_os_release_output) do
      <<~OS_RELEASE
        PRETTY_NAME="Ubuntu 26.04 LTS"
        NAME="Ubuntu"
        VERSION_ID="26.04"
        ID=ubuntu
        VERSION_CODENAME=resolute
      OS_RELEASE
    end

    it "bypasses the cache and re-fetches the file" do
      expect(session.os_version).to eq("24.04")

      # simulate the OS having changed since the connection opened (e.g. a distro upgrade)
      allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, upgraded_os_release_output)
      session.refresh_os_release

      expect(session.os_version).to eq("26.04")
      expect(mock_ssh_channel).to have_received(:exec).twice
    end
  end

  describe "#os_id, #os_version, #os_codename" do
    it "expose the parsed fields" do
      expect(session.os_id).to eq("ubuntu")
      expect(session.os_version).to eq("24.04")
      expect(session.os_codename).to eq("noble")
    end
  end

  describe "#os_codename?" do
    it "returns true when the codename matches" do
      expect(session.os_codename?("noble")).to be true
    end

    it "returns true when the codename matches any of several names" do
      expect(session.os_codename?("jammy", "noble")).to be true
    end

    it "returns false when the codename matches none" do
      expect(session.os_codename?("jammy", "resolute")).to be false
    end
  end

  describe "#ubuntu?" do
    it "returns true on Ubuntu" do
      expect(session.ubuntu?).to be true
    end
  end

  describe "#ubuntu_version_below?" do
    it "returns true when the current version is older" do
      expect(session.ubuntu_version_below?("26.04")).to be true
    end

    it "returns false when the current version is equal or newer" do
      expect(session.ubuntu_version_below?("24.04")).to be false
      expect(session.ubuntu_version_below?("22.04")).to be false
    end
  end

  describe "#ubuntu_version?" do
    it "supports single comparison operators" do
      expect(session.ubuntu_version?(">= 24.04")).to be true
      expect(session.ubuntu_version?(">= 26")).to be false
      expect(session.ubuntu_version?("< 26.04")).to be true
      expect(session.ubuntu_version?("= 24.04")).to be true
    end

    it "supports combining requirements into a range" do
      expect(session.ubuntu_version?(">= 24.04", "< 26.04")).to be true
      expect(session.ubuntu_version?(">= 25.04", "< 26.04")).to be false
    end

    it "treats a bare version with no operator as exact equality, not 'this release or newer'" do
      expect(session.ubuntu_version?("24.04")).to be true  # exact match against VERSION_ID
      expect(session.ubuntu_version?("24")).to be false    # "24" != "24.04" — not "any 24.x"
      expect(session.ubuntu_version?("26")).to be false    # use ">= 26" for that instead
    end

    context "on a non-Ubuntu host" do
      let(:os_release_output) do
        <<~OS_RELEASE
          PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
          NAME="Debian GNU/Linux"
          VERSION_ID="12"
          ID=debian
        OS_RELEASE
      end

      it "returns false regardless of the requirement" do
        expect(session.ubuntu_version?(">= 1")).to be false
      end
    end
  end
end
