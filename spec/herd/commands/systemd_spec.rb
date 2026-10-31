# frozen_string_literal: true

RSpec.describe Herd::Commands::Systemd do
  # visudo and systemctl themselves are exercised in spec/system/systemd_spec.rb.
  let(:session) { Herd::Session.new(nil, nil, "secret", StringIO.new) }

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe ".unit_name" do
    it "adds .service unless the name ends in a unit type" do
      { "puma" => "puma.service", "puma.service" => "puma.service", "backup.timer" => "backup.timer",
        "worker@reid.1" => "worker@reid.1.service", "app@" => "app@.service", "my.app" => "my.app.service" }
        .each { |name, unit| expect(described_class.unit_name(name)).to eq(unit) }
    end

    it "refuses names systemd wouldn't accept" do
      ["puma; reboot", "a b", "$(x)", ""].each do |name|
        expect { described_class.unit_name(name) }.to raise_error(ArgumentError)
      end
    end
  end

  describe "systemctl commands" do
    before { allow(session).to receive(:sudo) }

    it "normalize the unit name the same way systemd_unit does" do
      session.systemctl_restart("worker@reid.1")
      session.systemctl_enable("puma", now: true)

      expect(session).to have_received(:sudo).with("systemctl restart worker@reid.1.service")
      expect(session).to have_received(:sudo).with("systemctl enable --now puma.service")
    end
  end

  describe "#systemd_unit" do
    before do
      allow(session).to receive(:systemctl_daemon_reload)
      allow(session).to receive(:systemctl_enable)
    end

    it "writes the unit as root:root 644, appending .service to a bare name" do
      allow(session).to receive(:file).and_return(false)

      session.systemd_unit("puma", "[Unit]\n")

      expect(session).to have_received(:file)
        .with("/etc/systemd/system/puma.service", "root", "root", content: "[Unit]\n", mode: 644)
    end

    it "keeps an explicit suffix" do
      allow(session).to receive(:file).and_return(false)

      session.systemd_unit("backup.timer", "[Timer]\n")

      expect(session).to have_received(:file).with("/etc/systemd/system/backup.timer", any_args)
      expect(session).to have_received(:systemctl_enable).with("backup.timer")
    end

    it "daemon-reloads and returns true only when the unit changed" do
      allow(session).to receive(:file).and_return(true)

      expect(session.systemd_unit("puma", "[Unit]\n")).to be(true)
      expect(session).to have_received(:systemctl_daemon_reload)
    end

    it "skips daemon-reload when the unit is unchanged" do
      allow(session).to receive(:file).and_return(false)

      expect(session.systemd_unit("puma", "[Unit]\n")).to be(false)
      expect(session).not_to have_received(:systemctl_daemon_reload)
      expect(session).to have_received(:systemctl_enable).with("puma.service")
    end

    it "does not enable with enable: false, e.g. for template units" do
      allow(session).to receive(:file).and_return(true)

      session.systemd_unit("app@", "[Unit]\n", enable: false)

      expect(session).to have_received(:file).with("/etc/systemd/system/app@.service", any_args)
      expect(session).not_to have_received(:systemctl_enable)
    end
  end

  describe "#systemd_allow_actions" do
    let(:written) { [] }

    before do
      allow(session).to receive(:install_file) { |path, content, **opts| written << [path, content, opts] }
    end

    it "writes NOPASSWD lines for the default actions across all units, checked by visudo" do
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: %w[puma solid_queue.service])

      expected_content = <<~SUDOERS
        # Managed by Herd. Do not edit manually.

        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl start puma.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop puma.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart puma.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl status puma.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl start solid_queue.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop solid_queue.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart solid_queue.service
        footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl status solid_queue.service
      SUDOERS

      expect(written).to eq([["/etc/sudoers.d/00-app", expected_content,
                              { owner: "root", group: "root", mode: 440, sudo: true, validate: "visudo -cf %{staged}" }]])
    end

    it "escapes characters sudoers treats specially in a unit name" do
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "sys-dev:x", actions: %w[start])

      expect(written.last[1]).to include("/usr/bin/systemctl start sys-dev\\:x.service")
    end

    it "refuses a user or action that could change the rule" do
      expect { session.systemd_allow_actions("/x", user: "a ALL", units: "puma") }.to raise_error(ArgumentError)
      expect { session.systemd_allow_actions("/x", user: "a", units: "puma", actions: ["start *"]) }
        .to raise_error(ArgumentError)
      expect(written).to be_empty
    end

    it "documents that pointing two calls at the same sudoers_path overwrites rather than merges" do
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "puma")
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "solid_queue")

      # the second call's content is the last thing written — no trace of "puma" survives
      expect(written.last[1]).not_to include("puma")
      expect(written.last[1]).to include("solid_queue")
    end
  end
end
