# frozen_string_literal: true

RSpec.describe Herd::Commands::Postgres do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#psql" do
    it "runs psql as postgres, with the SQL in a quoted heredoc and vars shell-escaped" do
      allow(session).to receive(:run).and_return("1\r\n")

      expect(session.psql("SELECT :'pw'", db: "app", vars: { pw: "a'b c" })).to eq("1")
      expect(session).to have_received(:run).with(
        "sudo -p 'HERD_SUDO: ' -u postgres " \
        "psql -X -q -A -t -v ON_ERROR_STOP\\=1 -d app -v pw\\=a\\'b\\ c <<'HERD_SQL'\nSELECT :'pw'\nHERD_SQL"
      )
    end

    it "runs from / and restores the caller's directory" do
      dirs = []
      allow(session).to receive(:run) { dirs << session.instance_variable_get(:@working_dir) && "" }

      session.within("/app") do
        session.psql("SELECT 1")
        session.run("ls")
      end

      expect(dirs).to eq(["/", "/app"])
    end
  end

  describe "#pg_role_exists?" do
    it "passes the name as a psql variable" do
      allow(session).to receive(:psql).and_return("1")

      expect(session.pg_role_exists?("app")).to be(true)
      expect(session).to have_received(:psql).with("SELECT 1 FROM pg_roles WHERE rolname = :'name'", vars: { name: "app" })
    end

    it "is false on empty output" do
      allow(session).to receive(:psql).and_return("")
      expect(session.pg_role_exists?("app")).to be(false)
    end
  end

  describe "#pg_role" do
    before { allow(session).to receive(:psql).and_return("") }

    it "creates a missing role with attributes and a quoted password" do
      allow(session).to receive(:pg_role_exists?).and_return(false)

      expect(session.pg_role("repl", password: "pw", attributes: %w[login replication])).to be(true)
      expect(session).to have_received(:psql)
        .with(%(CREATE ROLE :"name" WITH LOGIN REPLICATION PASSWORD :'password'), vars: { name: "repl", password: "pw" })
    end

    it "alters an existing role" do
      allow(session).to receive(:pg_role_exists?).and_return(true)

      expect(session.pg_role("repl", password: "pw")).to be(false)
      expect(session).to have_received(:psql).with(%(ALTER ROLE :"name" WITH LOGIN PASSWORD :'password'), any_args)
    end

    it "does nothing for an existing role with nothing to set" do
      allow(session).to receive(:pg_role_exists?).and_return(true)

      session.pg_role("repl", attributes: [])
      expect(session).not_to have_received(:psql)
    end

    it "rejects anything that isn't a role attribute" do
      expect { session.pg_role("x", attributes: ["LOGIN; DROP"]) }.to raise_error(ArgumentError, /unknown attribute/)
    end
  end

  describe "#pg_cluster_status" do
    let(:clusters) { [{ version: "18", cluster: "main", running: 1 }, { version: "16", cluster: "main", running: 0 }] }

    before { allow(session).to receive(:run).and_return(clusters.to_json) }

    it "reports online, offline and missing clusters" do
      expect(session.pg_cluster_status("18")).to eq(:online)
      expect(session.pg_cluster_status(16)).to eq(:offline)
      expect(session.pg_cluster_status("17")).to eq(:missing)
    end
  end

  describe "#pg_wait_ready" do
    before { allow(session).to receive(:sleep) }

    it "polls until postgres accepts connections" do
      allow(session).to receive(:pg_ready?).and_return(false, false, true)

      session.pg_wait_ready
      expect(session).to have_received(:sleep).twice
    end

    it "raises after the timeout" do
      allow(session).to receive(:pg_ready?).and_return(false)

      expect { session.pg_wait_ready(timeout: 0) }.to raise_error(Herd::CommandError, /after 0s/)
    end
  end
end
