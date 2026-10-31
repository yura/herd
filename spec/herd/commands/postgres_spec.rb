# frozen_string_literal: true

RSpec.describe Herd::Commands::Postgres do
  # What a real psql does with the script is in spec/system/postgres_spec.rb.
  let(:session) { Herd::Session.new(nil, nil, "secret", StringIO.new) }

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#psql" do
    let(:upload) { Herd::Transport::Upload.new(path: "/tmp/herd-upload.x", sensitive: false) }

    before do
      allow(session).to receive(:with_upload).and_yield(upload)
      allow(session).to receive(:run).and_return("1\r\n")
    end

    it "runs psql as postgres on an uploaded script, with no SQL or values on the command line" do
      expect(session.psql("SELECT :'pw'", db: "app", vars: { pw: "a'b c" })).to eq("1")

      expect(session).to have_received(:with_upload).with("\\set pw 'a''b c'\nSELECT :'pw'\n", sensitive: false)
      expect(session).to have_received(:run).with(
        "sudo -p 'HERD_SUDO: ' -u postgres psql -X -q -A -t -v ON_ERROR_STOP\\=1 -d app -f - < /tmp/herd-upload.x",
        sensitive: false, sudo_prompt: true
      )
    end

    it "runs from / and restores the caller's directory" do
      dirs = []
      allow(session).to receive(:run) { (dirs << session.instance_variable_get(:@working_dir)) && "" }

      session.within("/app") do
        session.psql("SELECT 1")
        session.run("ls")
      end

      expect(dirs).to eq(["/", "/app"])
    end

    it "writes each \\set on one line: backslashes doubled first, line breaks and tabs as escapes" do
      script = session.send(:psql_script, "SELECT 1", { v: "a\\b\nc\rd\te'f" })

      expect(script).to eq("\\set v 'a\\\\b\\nc\\rd\\te''f'\nSELECT 1\n")
    end

    it "refuses variable names that could reach psql's own variables, NUL and invalid UTF-8" do
      ["ON_ERROR_STOP", "x y", "1x"].each do |name|
        expect { session.send(:psql_script, "", { name => "v" }) }.to raise_error(ArgumentError)
      end
      expect { session.send(:psql_script, "", { v: "a\0b" }) }.to raise_error(ArgumentError, /NUL/)
      expect { session.send(:psql_script, "", { v: "\xFF".b }) }.to raise_error(ArgumentError, /UTF-8/)
    end
  end

  describe "#psql_json" do
    it "wraps the query in json_agg and parses rows, including multi-line output" do
      allow(session).to receive(:psql).and_return(%([{"a":1,"b":"x"}, \r\n {"a":2,"b":null}]))

      expect(session.psql_json("SELECT a, b FROM t",
                               db: "app")).to eq([{ "a" => 1, "b" => "x" }, { "a" => 2, "b" => nil }])
      expect(session).to have_received(:psql)
        .with("SELECT coalesce(json_agg(q), '[]'::json) FROM (SELECT a, b FROM t) q", db: "app", vars: {})
    end
  end

  describe "#pg_role_exists?" do
    it "passes the name as a psql variable" do
      allow(session).to receive(:psql).and_return("1")

      expect(session.pg_role_exists?("app")).to be(true)
      expect(session).to have_received(:psql).with("SELECT 1 FROM pg_roles WHERE rolname = :'name'",
                                                   vars: { name: "app" })
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
        .with(%(CREATE ROLE :"name" WITH LOGIN REPLICATION PASSWORD :'password'), vars: { name: "repl", password: "pw" },
                                                                                  sensitive: true)
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

    def lsclusters(stdout, exit_code = 0)
      allow(session).to receive(:run_result).and_return(Herd::CommandResult.new(stdout: stdout, exit_code: exit_code))
    end

    it "reports online, offline and missing clusters" do
      lsclusters(clusters.to_json)

      expect(session.pg_cluster_status("18")).to eq(:online)
      expect(session.pg_cluster_status(16)).to eq(:offline)
      expect(session.pg_cluster_status("17")).to eq(:missing)
    end

    it "reports missing without postgresql-common, and raises when pg_lsclusters fails" do
      lsclusters("", 127)
      expect(session.pg_cluster_status("18")).to eq(:missing)

      lsclusters("", 1)
      expect { session.pg_cluster_status("18") }.to raise_error(Herd::CommandError)
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
