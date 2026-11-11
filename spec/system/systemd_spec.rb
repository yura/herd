# frozen_string_literal: true

require_relative "system_helper"

# The container doesn't run systemd, but it has the real visudo and sudo that
# systemd_allow_actions depends on.
RSpec.describe Herd::Commands::Systemd, :system do
  def sudoers_file = "/etc/sudoers.d/90-herd-spec-#{SecureRandom.hex(3)}"

  it "installs a sudoers rule visudo accepts, root:root 440, and sudo applies it" do
    path = sudoers_file
    with_system_session do |s, _|
      expect(s.systemd_allow_actions(path, user: "herd", units: %w[puma worker@reid.1])).to be(true)
      expect(s.systemd_allow_actions(path, user: "herd", units: %w[puma worker@reid.1])).to be(false)

      expect(s.sudo("stat -c '%U:%G %a' -- #{s.shell_path(path)}").strip).to eq("root:root 440")
      expect(s.sudo("sudo -l -U herd")).to include("/usr/bin/systemctl restart worker@reid.1.service")
    ensure
      s.sudo("rm -f -- #{s.shell_path(path)}")
    end
  end

  it "leaves /etc/sudoers.d untouched when visudo rejects the file" do
    path = sudoers_file
    with_system_session do |s, _|
      expect do
        s.install_file(path, "herd ALL=(ALL) NOPASSWD: /bin/true,\n", owner: "root", mode: 440, sudo: true,
                                                                      validate: "visudo -cf %{staged}")
      end.to raise_error(Herd::CommandError, /syntax error/)

      expect(s.sudo("ls -A /etc/sudoers.d")).not_to include("herd-spec")
      expect(s.sudo("whoami").strip).to eq("root")
    end
  end
end
