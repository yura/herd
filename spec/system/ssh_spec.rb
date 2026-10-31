# frozen_string_literal: true

require_relative "system_helper"

RSpec.describe Herd::Commands::Ssh, :system do
  def mode_of(s, path) = s.run("stat -c %a -- #{s.shell_path(path)}", pty: false).strip

  describe "for a fresh user without ~/.ssh" do
    it "sets up a deploy key, its alias and known_hosts" do
      user     = "herdfresh#{SecureRandom.hex(3)}"
      password = "fresh-#{SecureRandom.hex(6)}"
      with_system_session do |s, _|
        s.user_create(user)
        s.change_password(user, password)
      end

      login = Herd::Host.new(system_host.host, system_host.explicit_ssh_options.merge(user: user, password: password))
      with_host_session(login) do |s|
        expect(s.file_exists?("~/.ssh")).to be(false)

        pub = s.ssh_deploy_key("app", git_host: "git.example.com",
                                      known_hosts: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQ"])

        expect(pub).to start_with("ssh-ed25519 ")
        expect(s.read_file("~/.ssh/config")).to start_with("Include ~/.ssh/config.d/*.conf")
        expect(s.read_file("~/.ssh/config.d/app.conf")).to include("Host git-app",
                                                                   "IdentityFile ~/.ssh/deploy_keys/app_ed25519")
        expect(s.read_file("~/.ssh/known_hosts.d/git.example.com"))
          .to eq("git.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIQ")
        expect(%w[~/.ssh ~/.ssh/config ~/.ssh/config.d/app.conf ~/.ssh/deploy_keys/app_ed25519].map { mode_of(s, it) })
          .to eq(%w[700 600 600 600])
      end
    ensure
      on_system_host { sudo("userdel -r #{user}") }
    end

    it "creates the directory of a new key" do
      with_system_session do |s, dir|
        s.ssh_keygen("#{dir}/keys/new/id_ed25519")

        expect(mode_of(s, "#{dir}/keys/new")).to eq("700")
        expect(s.file_exists?("#{dir}/keys/new/id_ed25519.pub")).to be(true)
      end
    end
  end

  describe "#sshd_disable_accept_env" do
    # sshd_config is shared by every example: keep the original and put it back.
    around do |example|
      on_system_host(:nopass) { sudo("cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.herd-spec") }
      example.run
    ensure
      on_system_host(:nopass) do
        sudo("sh -c 'mv -f /etc/ssh/sshd_config.herd-spec /etc/ssh/sshd_config; " \
             "rm -f /etc/ssh/sshd_config.d/90-herd-spec.conf* /etc/ssh/sshd_config*.herd-bak'")
      end
    end

    def accept_env(s) = s.sudo("sshd -T").lines.grep(/\Aacceptenv /i)

    it "comments out AcceptEnv in sshd_config and drop-ins, indented ones too, and validates the result" do
      with_system_session(:nopass) do |s, _|
        allow(s).to receive(:systemctl_reload)
        s.install_file("/etc/ssh/sshd_config.d/90-herd-spec.conf", "  acceptenv HERD_*\n", sudo: true)
        expect(accept_env(s)).not_to be_empty

        expect(s.sshd_disable_accept_env).to be(true)
        expect(accept_env(s)).to be_empty
        expect(s.read_file("/etc/ssh/sshd_config.d/90-herd-spec.conf", sudo: true)).to eq("  #acceptenv HERD_*")
        expect(s).to have_received(:systemctl_reload).with("ssh")
        expect(s.sshd_disable_accept_env).to be(false)
      end
    end

    it "raises when AcceptEnv stays in effect from a file Included from elsewhere, also on the no-op path" do
      with_system_session(:nopass) do |s, _|
        allow(s).to receive(:systemctl_reload)
        s.sshd_disable_accept_env
        s.install_file("/etc/ssh/herd-spec-extra.conf", "AcceptEnv HERD_EXTRA\n", sudo: true)
        s.sudo("sh -c 'echo Include /etc/ssh/herd-spec-extra.conf >> /etc/ssh/sshd_config'")

        expect { s.sshd_disable_accept_env }.to raise_error(Herd::CommandError, /still accepts.*HERD_EXTRA/i)
      ensure
        s.sudo("rm -f /etc/ssh/herd-spec-extra.conf")
      end
    end

    it "puts every file back when the edited config fails sshd -t" do
      with_system_session(:nopass) do |s, _|
        allow(s).to receive(:systemctl_reload)
        s.install_file("/etc/ssh/sshd_config.d/90-herd-spec.conf", "AcceptEnv HERD_*\nNoSuchOption yes\n", sudo: true)
        before = s.read_bytes("/etc/ssh/sshd_config", sudo: true)

        expect { s.sshd_disable_accept_env }.to raise_error(Herd::CommandError)
        expect(s.read_bytes("/etc/ssh/sshd_config", sudo: true)).to eq(before)
        expect(s.read_file("/etc/ssh/sshd_config.d/90-herd-spec.conf", sudo: true)).to start_with("AcceptEnv HERD_*")
        expect(s).not_to have_received(:systemctl_reload)
      end
    end
  end
end
