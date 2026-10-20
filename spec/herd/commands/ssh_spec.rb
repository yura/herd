# frozen_string_literal: true

RSpec.describe Herd::Commands::Ssh do
  let(:session) { Herd::Session.new(host, mock_ssh_session, "secret", mock_log) }
  let(:host) { Herd::Host.new("10.0.0.1", user: "deploy") }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }
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

  describe "#ssh_deploy_key" do
    let(:written) { {} }

    before do
      allow(session).to receive(:run).and_return("")
      allow(session).to receive(:file_contains?).and_return(true)
      allow(session).to receive(:ssh_keygen).and_return("ssh-ed25519 AAAApub app@deploy@10.0.0.1")
      allow(session).to receive(:expect_file_content_equals) { |path, content| written[path] = content }
      allow(described_class).to receive(:github_ssh_keys).and_return(github_keys)
    end

    it "returns the public key of a per-repo key" do
      expect(session.ssh_deploy_key("app")).to eq("ssh-ed25519 AAAApub app@deploy@10.0.0.1")
      expect(session).to have_received(:ssh_keygen).with("~/.ssh/deploy_keys/app_ed25519", comment: "app@deploy@10.0.0.1")
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
