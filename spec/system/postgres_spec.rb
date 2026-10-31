# frozen_string_literal: true

require_relative "system_helper"

# psql against the PostgreSQL running in the container.
RSpec.describe Herd::Commands::Postgres, :system do
  values = {
    "a quote" => "it's",
    "a backslash" => "C:\\dir\\n",
    "LF" => "line1\nline2",
    "CR" => "a\rb",
    "CRLF" => "a\r\nb",
    "a tab" => "a\tb",
    "Unicode" => "пароль ✓",
    "psql syntax" => ":'x' \\q \\! touch /tmp/pwned",
    "a heredoc delimiter" => "x\nHERD_SQL\nDROP TABLE y;"
  }

  values.each do |label, value|
    it "passes a value with #{label} through a variable unchanged" do
      with_system_session do |s, _|
        expect(s.psql("SELECT encode(convert_to(:'v', 'UTF8'), 'hex')", vars: { v: value }))
          .to eq(value.unpack1("H*"))
        expect(s.command_success?("test -e /tmp/pwned")).to be(false)
      end
    end
  end

  it "runs multi-statement SQL and stops at the first error" do
    with_system_session do |s, _|
      expect { s.psql("SELECT 1; SELECT no_such_column FROM pg_roles; SELECT 3") }.to raise_error(Herd::CommandError)
      expect(s.psql("SELECT 1 UNION ALL SELECT 2")).to eq("1\n2")
    end
  end

  it "creates and alters a role with a password kept out of the log, and the password works" do
    with_system_session do |s, _|
      role = "herd_role_#{SecureRandom.hex(3)}"
      password = "s3cr'et \\ pa$$ #{SecureRandom.hex(4)}"

      expect(s.pg_role(role, password: password, attributes: %w[LOGIN])).to be(true)
      expect(s.pg_role_exists?(role)).to be(true)
      expect(s.pg_role(role, password: password)).to be(false)

      # Logging in over TCP with exactly that password proves it arrived unchanged.
      # In a .pgpass line ":" and "\\" are escaped with a backslash.
      pgpass = "127.0.0.1:*:*:#{role}:#{password.gsub(/[:\\]/) { "\\#{it}" }}\n"
      login = s.with_upload(pgpass, sensitive: true) do |file|
        s.run("PGPASSFILE=#{file.shell_path} psql -h 127.0.0.1 -U #{role} -d postgres -Atc 'SELECT current_user'",
              pty: false, sensitive: true).strip
      end
      expect(login).to eq(role)
      expect(Dir["log/**/*.jsonl"].map { File.read(it) }.join).not_to include(password)
    ensure
      s.psql(%(DROP ROLE IF EXISTS :"r"), vars: { r: role }) if role
    end
  end

  it "parses rows into hashes with psql_json" do
    with_system_session do |s, _|
      rows = s.psql_json("SELECT * FROM (VALUES (1, 'a'), (2, NULL)) t(n, s)")
      expect(rows).to eq([{ "n" => 1, "s" => "a" }, { "n" => 2, "s" => nil }])
    end
  end

  it "reports the cluster as online" do
    with_system_session do |s, _|
      version = s.run("ls /etc/postgresql", pty: false).strip
      expect([s.pg_cluster_status(version), s.pg_cluster_status("99"), s.pg_ready?]).to eq([:online, :missing, true])
    end
  end
end
