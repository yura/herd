# frozen_string_literal: true

require "json"
require "shellwords"

module Herd
  module Commands
    # PostgreSQL administration as the postgres superuser, via psql over peer auth.
    module Postgres
      PSQL_VARIABLE = /\A[a-z_][a-z0-9_]*\z/
      ROLE_ATTRIBUTE = /\A(NO)?(SUPERUSER|CREATEDB|CREATEROLE|INHERIT|LOGIN|REPLICATION|BYPASSRLS)\z/

      # Returns the trimmed output (tuples only, "|"-separated, rows joined with "\n"). vars become psql
      # variables: write :'name' for a literal, :"name" for an identifier, and psql quotes them.
      #
      # The SQL and the variables reach psql in an uploaded file (psql -f -), never on the
      # command line or in a heredoc. sensitive: true keeps the statement and its output out
      # of the log — use it when vars carry a password.
      def psql(sql, db: nil, vars: {}, sensitive: false)
        script = psql_script(sql, vars)
        # From /: postgres can't enter a 750 home and psql would warn into the output.
        output = within("/") do
          with_upload(script, sensitive: sensitive) do |file|
            sudo("-u postgres #{psql_command(db)} < #{file.shell_path}", sensitive: sensitive)
          end
        end
        # Rows end in "\r\r\n" by the time they arrive: sudo's own PTY (use_pty) and the
        # session's each turn "\n" into "\r\n".
        output.gsub(/\r+\n/, "\n").strip
      end

      # Rows as hashes keyed by column name, built by Postgres itself via json_agg.
      # sql is a single SELECT without a trailing semicolon.
      def psql_json(sql, db: nil, vars: {})
        JSON.parse(psql("SELECT coalesce(json_agg(q), '[]'::json) FROM (#{sql}) q", db: db, vars: vars))
      end

      def pg_role_exists?(name)
        psql("SELECT 1 FROM pg_roles WHERE rolname = :'name'", vars: { name: name }) == "1"
      end

      def pg_database_exists?(name)
        psql("SELECT 1 FROM pg_database WHERE datname = :'name'", vars: { name: name }) == "1"
      end

      def pg_setting(name)
        psql("SELECT current_setting(:'name')", vars: { name: name })
      end

      # Creates the role, or brings an existing one to these attributes and password.
      # Returns true if the role was created.
      def pg_role(name, password: nil, attributes: %w[LOGIN])
        options = attributes.map { |attribute| pg_role_attribute(attribute) }
        options << "PASSWORD :'password'" if password

        created = !pg_role_exists?(name)
        return false if !created && options.empty?

        sql = %(#{created ? "CREATE" : "ALTER"} ROLE :"name")
        sql += " WITH #{options.join(" ")}" if options.any?
        secret(password) if password
        psql(sql, vars: { name: name, password: password }.compact, sensitive: !password.nil?)
        created
      end

      # :missing, :offline or :online, from pg_lsclusters (postgresql-common).
      def pg_cluster_status(version, cluster = "main")
        result = run_result("pg_lsclusters -js", pty: false)
        # 127: postgresql-common isn't installed, so there is no cluster at all.
        return :missing if result.exit_code == 127
        raise Herd::CommandError, "pg_lsclusters: #{result.stderr.strip}" unless result.success?

        clusters = JSON.parse(result.stdout)
        found    = clusters.find { |c| c["version"].to_s == version.to_s && c["cluster"] == cluster }
        return :missing unless found

        found["running"] == 1 ? :online : :offline
      end

      def pg_ready?
        command_success?("pg_isready -q")
      end

      def pg_wait_ready(timeout: 30)
        deadline = Time.now + timeout
        until pg_ready?
          raise Herd::CommandError, "postgresql not accepting connections after #{timeout}s" if Time.now > deadline

          sleep 1
        end
      end

      private

      def psql_command(db)
        flags = ["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
        flags.push("-d", db.to_s) if db
        "psql #{shell_args(flags)} -f -"
      end

      # \set lines for vars, then the SQL. Names are lower case so they can't hit psql's own
      # variables (ON_ERROR_STOP, AUTOCOMMIT, ...). In a quoted \set argument psql reads
      # \\ \n \r \t as escapes and '' as a quote, so backslashes are doubled first, then
      # real line breaks and tabs are written as escapes: each \set stays one line.
      def psql_script(sql, vars)
        lines = vars.map do |name, value|
          name = name.to_s
          unless name.match?(PSQL_VARIABLE)
            raise ArgumentError,
                  "psql: variable name #{name.inspect} must match [a-z_][a-z0-9_]*"
          end

          "\\set #{name} '#{psql_quote(value.to_s, name)}'"
        end
        "#{(lines + [sql]).join("\n")}\n"
      end

      def psql_quote(value, name)
        unless value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          raise ArgumentError, "psql: #{name} is not valid UTF-8"
        end
        raise ArgumentError, "psql: #{name} contains NUL, which PostgreSQL text can't hold" if value.include?("\0")

        # Blocks, not replacement strings: gsub reads backslashes in a replacement string.
        value.gsub("\\") { "\\\\" }.gsub("\n") { "\\n" }.gsub("\r") { "\\r" }.gsub("\t") { "\\t" }.gsub("'") { "''" }
      end

      def pg_role_attribute(attribute)
        attribute = attribute.to_s.upcase
        raise ArgumentError, "pg_role: unknown attribute #{attribute}" unless attribute.match?(ROLE_ATTRIBUTE)

        attribute
      end
    end
  end
end
