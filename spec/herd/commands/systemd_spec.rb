# frozen_string_literal: true

RSpec.describe Herd::Commands::Systemd do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#systemd_allow_actions" do
    before do
      allow(session).to receive(:expect_file_content_equals)
      allow(session).to receive(:file_permissions)
    end

    it "writes NOPASSWD lines for the default actions across all units" do
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: %w[puma solid_queue])

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

      expect(session).to have_received(:expect_file_content_equals).with("/etc/sudoers.d/00-app", expected_content)
    end

    it "accepts a single unit as a bare string" do
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "puma")

      expect(session).to have_received(:expect_file_content_equals) do |_path, content|
        expect(content).to include("footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl start puma.service")
      end
    end

    it "restricts to the given actions when overridden" do
      session.systemd_allow_actions("/etc/sudoers.d/01-nginx", user: "footbot", units: "nginx", actions: %w[reload])

      expect(session).to have_received(:expect_file_content_equals) do |_path, content|
        expect(content).to include("footbot ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx.service")
        expect(content).not_to include("start")
      end
    end

    it "sets sudoers file permissions to 440" do
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "puma")
      expect(session).to have_received(:file_permissions).with("/etc/sudoers.d/00-app", 440)
    end

    it "documents that pointing two calls at the same sudoers_path overwrites rather than merges" do
      written = []
      allow(session).to receive(:expect_file_content_equals) { |_path, content| written << content }

      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "puma")
      session.systemd_allow_actions("/etc/sudoers.d/00-app", user: "footbot", units: "solid_queue")

      # the second call's content is the last thing written — no trace of "puma" survives
      expect(written.last).not_to include("puma")
      expect(written.last).to include("solid_queue")
    end
  end
end
