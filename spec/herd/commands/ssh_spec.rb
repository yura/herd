# frozen_string_literal: true

RSpec.describe Herd::Commands::Ssh do
  # Fresh users, real sshd -t/-T and the AcceptEnv rollback are in spec/system/ssh_spec.rb.
  let(:session) { Herd::Session.new(host, nil, "secret", StringIO.new) }
  let(:host) { Herd::Host.new("10.0.0.1", user: "deploy") }
  let(:github_keys) { ["ssh-ed25519 AAAAgh", "ssh-rsa AAAArsa"] }

  after { described_class.instance_variable_set(:@github_ssh_keys, nil) }

  describe ".github_ssh_keys" do
    it "returns ssh_keys from the GitHub meta API, fetching once" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:body).and_return({ ssh_keys: github_keys }.to_json)
      allow(Net::HTTP).to receive(:get_response).and_return(response)

      2.times { expect(described_class.github_ssh_keys).to eq(github_keys) }
      expect(Net::HTTP).to have_received(:get_response).once
    end

    it "raises when the API answers with an error" do
      allow(Net::HTTP).to receive(:get_response).and_return(Net::HTTPForbidden.new("1.1", "403", "Forbidden"))
      allow_any_instance_of(Net::HTTPForbidden).to receive(:body).and_return("rate limited") # rubocop:disable RSpec/AnyInstance

      expect { described_class.github_ssh_keys }.to raise_error(Herd::CommandError, /403/)
    end
  end

  describe "#sshd_reload" do
    it "doesn't reload a config sshd -t rejects" do
      allow(session).to receive(:sudo).with("sshd -t").and_raise(Herd::CommandError, "bad config")
      allow(session).to receive(:systemctl_reload)

      expect { session.sshd_reload }.to raise_error(Herd::CommandError, /bad config/)
      expect(session).not_to have_received(:systemctl_reload)
    end
  end

  describe "AcceptEnv lines" do
    it "match at any indentation and in any case, but not a commented-out line" do
      text = "AcceptEnv LANG\n  acceptenv LC_*\n\tAcceptEnv X\n#AcceptEnv Y\nAcceptEnvironment Z\n"
      edited = text.gsub(described_class::ACCEPT_ENV) { "#{Regexp.last_match(1)}##{Regexp.last_match(2)}" }

      expect(edited).to eq("#AcceptEnv LANG\n  #acceptenv LC_*\n\t#AcceptEnv X\n#AcceptEnv Y\nAcceptEnvironment Z\n")
    end
  end

  describe "#ssh_deploy_key" do
    let(:written) { {} }

    before do
      allow(session).to receive(:run).and_return("")
      allow(session).to receive(:file_contains?).and_return(true)
      allow(session).to receive(:ssh_keygen).and_return("ssh-ed25519 AAAApub app@deploy@10.0.0.1")
      allow(session).to receive(:install_file) { |path, content, **| written[path] = content }
      allow(described_class).to receive(:github_ssh_keys).and_return(github_keys)
    end

    it "returns the public key of a per-repo key" do
      expect(session.ssh_deploy_key("app")).to eq("ssh-ed25519 AAAApub app@deploy@10.0.0.1")
      expect(session).to have_received(:ssh_keygen).with("~/.ssh/deploy_keys/app_ed25519",
                                                         comment: "app@deploy@10.0.0.1")
    end

    it "writes a github-<name> alias pinned to its own known_hosts file" do
      session.ssh_deploy_key("app")

      expect(written["~/.ssh/config.d/app.conf"]).to eq(<<~CONF)
        Host github-app
          HostName github.com
          User git
          IdentitiesOnly yes
          IdentityFile ~/.ssh/deploy_keys/app_ed25519
          UserKnownHostsFile ~/.ssh/known_hosts.d/github.com
      CONF
    end

    it "replaces the known_hosts file with the keys GitHub currently publishes" do
      session.ssh_deploy_key("app")

      expect(written["~/.ssh/known_hosts.d/github.com"])
        .to eq("github.com ssh-ed25519 AAAAgh\ngithub.com ssh-rsa AAAArsa")
    end

    it "takes explicit known_hosts for other git hosts" do
      session.ssh_deploy_key("app", git_host: "gitlab.com", known_hosts: ["ssh-ed25519 AAAAgl"])

      expect(written["~/.ssh/known_hosts.d/gitlab.com"]).to eq("gitlab.com ssh-ed25519 AAAAgl")
      expect(written["~/.ssh/config.d/app.conf"]).to start_with("Host gitlab-app\n")
    end

    it "creates ~/.ssh before touching ~/.ssh/config" do
      order = []
      allow(session).to receive(:run) { |cmd, **| order << cmd and "" }
      allow(session).to receive(:file_contains?) { order << :config and true }

      session.ssh_deploy_key("app")

      expect(order.first).to start_with("mkdir -p -m 700 -- \"$HOME\"/.ssh ")
      expect(order.index(:config)).to be > 0
    end

    it "refuses names that would escape ~/.ssh or the alias" do
      ["../x", "a b", "a\nHost *"].each do |name|
        expect { session.ssh_deploy_key(name) }.to raise_error(ArgumentError)
      end
    end

    it "refuses a non-GitHub host without known_hosts" do
      expect { session.ssh_deploy_key("app", git_host: "gitlab.com") }.to raise_error(ArgumentError, /known_hosts/)
    end

    it "prepends the config.d Include when ~/.ssh/config lacks it" do
      allow(session).to receive(:file_contains?).with("~/.ssh/config", described_class::CONFIG_D_INCLUDE)
                                                .and_return(false)
      allow(session).to receive(:prepend_to_file)

      session.ssh_deploy_key("app")

      expect(session).to have_received(:prepend_to_file).with("~/.ssh/config", "Include ~/.ssh/config.d/*.conf")
    end
  end
end
