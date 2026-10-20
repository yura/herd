# frozen_string_literal: true

RSpec.describe Herd::Inventory do
  subject(:inventory) { described_class.load(File.expand_path("../fixtures/inventory", __dir__)) }

  it "loads _common.rb first and skips other _-prefixed files" do
    expect(inventory.servers.keys).to eq(["web"])
    expect(inventory.servers["web"]).to include(ubuntu_locale: "en_US.UTF-8", db_password: "shared")
  end

  it "records which file registered each server" do
    expect(inventory.servers["web"][:config_file]).to end_with("fixtures/inventory/web.rb")
  end

  describe "#hosts" do
    let(:host) { inventory.hosts("web").first }

    it "takes SSH settings from the server config" do
      expect(host.host).to eq("10.0.0.1")
      expect(host.user).to eq("deploy")
      expect(host.port).to eq(2222)
      expect(host.password).to eq("pw")
    end

    it "puts everything else into vars, with the server name as hostname" do
      expect(host.vars).to include(hostname: "web", rustdesk_id: "123", root_password: "rootpw")
      expect(host.vars).not_to include(:password, :identity_file)
    end

    it "overrides the user and picks another password key on request" do
      root = inventory.hosts("web", user: "root", password: :root_password).first

      expect(root.user).to eq("root")
      expect(root.password).to eq("rootpw")
    end

    it "raises on an unknown server" do
      expect { inventory.hosts("nope") }.to raise_error(ArgumentError, /unknown server: nope/)
    end
  end
end
