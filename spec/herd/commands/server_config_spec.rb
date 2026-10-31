# frozen_string_literal: true

require "tmpdir"

RSpec.describe Herd::Commands::ServerConfig do
  let(:dir) { Dir.mktmpdir }
  let(:file) { File.join(dir, "web.rb") }
  let(:inventory) { Herd::Inventory.load(dir) }
  let(:session) { session_for("web") }

  def session_for(name)
    Herd::Session.new(inventory.hosts(name).first, nil, nil, nil).tap { |s| allow(s).to receive(:info) }
  end

  before do
    File.write(file, <<~RUBY)
      # rustdesk_id: nil
      register_server "web",
        host:          "10.0.0.1",
        db_password:   "keep",
        repl_password:     nil,
        rustdesk_id:   "old"

      register_server "db",
        host:          "10.0.0.2",
        rustdesk_id:   nil,
        computed:      ENV["X"]
    RUBY
  end

  after { FileUtils.remove_entry(dir) }

  describe "#server_secret" do
    it "returns an existing value without touching the file" do
      expect { expect(session.server_secret(:db_password)).to eq("keep") }.not_to(change { File.read(file) })
    end

    it "generates and saves a value for a nil key, keeping the alignment" do
      secret = session.server_secret(:repl_password)

      expect(secret).to match(/\A[A-Za-z0-9]{22}\z/)
      expect(File.read(file)).to include(%(repl_password:     '#{secret}'))
    end

    it "returns the saved value to another Host from the same inventory, syncing its vars" do
      first  = session_for("web").server_secret(:repl_password)
      second = session_for("web")

      expect(second.server_secret(:repl_password)).to eq(first)
      expect(second.host.vars[:repl_password]).to eq(first)
    end

    it "returns a value that comes via **common" do
      File.write(File.join(dir, "_common.rb"), %(common shared_password: "from-common"\n))
      File.write(file, File.read(file).sub(%(register_server "web",\n), %(register_server "web",\n  **common,\n)))

      expect(session.server_secret(:shared_password)).to eq("from-common")
    end

    it "uses the loaded value of an expression" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("X").and_return("from-env")

      expect(session_for("db").server_secret(:computed)).to eq("from-env")
    end
  end

  describe "#server_config_set" do
    it "rewrites only the value, in this server's call" do
      session.server_config_set(:rustdesk_id, "new")

      expect(File.read(file)).to include(%(rustdesk_id:   'new')).and include(%(db_password:   "keep"))
      expect(File.read(file)).to include("# rustdesk_id: nil").and include(%(rustdesk_id:   nil,))
      expect(session.host.vars[:rustdesk_id]).to eq("new")
    end

    it "targets the right server when a file registers several" do
      session_for("db").server_config_set(:rustdesk_id, "for-db")

      expect(File.read(file)).to include(%(rustdesk_id:   "old")).and include(%(rustdesk_id:   'for-db'))
    end

    it "round-trips values that need escaping, rewrite after rewrite" do
      session.server_config_set(:rustdesk_id, %(it's "quoted" \\ \#{x}))
      expect(session.server_config_get(:rustdesk_id)).to eq(%(it's "quoted" \\ \#{x}))

      session.server_config_set(:rustdesk_id, "plain")
      expect(Herd::Inventory.load(dir).servers["web"][:rustdesk_id]).to eq("plain")
    end

    it "refuses a key missing for this server" do
      expect { session.server_config_set(:password, "x") }.to raise_error(Herd::CommandError, /password not found/)
    end

    it "refuses to rewrite anything but nil or a one-line string" do
      expect do
        session_for("db").server_config_set(:computed, "x")
      end.to raise_error(Herd::CommandError, /not nil or a one-line/)
    end

    it "refuses a heredoc, leaving the file loadable" do
      File.write(file, %(register_server "web",\n  host: "10.0.0.1",\n  token: <<~T\n    old\n  T\n))

      expect { session.server_config_set(:token, "new") }.to raise_error(Herd::CommandError, /one-line/)
      expect(Herd::Inventory.load(dir).servers["web"][:token]).to eq("old\n")
    end

    context "when a **splat follows the key" do
      before do
        File.write(File.join(dir, "_common.rb"), %(common token: "from-common"\n))
        File.write(file, %(register_server "web",\n  host: "10.0.0.1",\n  token: nil,\n  **common\n))
      end

      it "reads the value Ruby actually loaded" do
        expect(session.server_secret(:token)).to eq("from-common")
      end

      it "refuses to write, since the splat would win on reload" do
        expect do
          session.server_config_set(:token, "x")
        end.to raise_error(Herd::CommandError, /overridden by a later \*\*splat/)
      end
    end
  end

  it "refuses a host that didn't come from an inventory" do
    plain = Herd::Session.new(Herd::Host.new("10.0.0.2"), nil, nil, nil)
    expect { plain.server_config_key!(:x) }.to raise_error(ArgumentError, /not loaded from an inventory/)
  end

  describe "two herd processes writing the same inventory file" do
    let(:keys) { (0...40).map { |i| :"k#{i}" } }

    before do
      File.write(file, %(register_server "web",\n  host: "10.0.0.1",\n#{keys.map { |k| "  #{k}: nil" }.join(",\n")}\n))
    end

    it "keeps every value each of them saved" do
      pids = keys.each_slice(20).map do |slice|
        fork do
          s = session_for("web")
          slice.each { |key| s.server_secret(key) }
          exit!(0)
        end
      end
      pids.each { |pid| Process.wait(pid) }

      saved = Herd::Inventory.load(dir).servers.fetch("web")
      expect(keys.count { |key| saved[key] }).to eq(40)
    end
  end
end
