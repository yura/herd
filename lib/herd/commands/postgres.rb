# frozen_string_literal: true

require "json"
require "shellwords"

module Herd
  module Commands
    # PostgreSQL administration as the postgres superuser, via psql over peer auth.
    module Postgres
      ROLE_ATTRIBUTE = /\A(NO)?(SUPERUSER|CREATEDB|CREATEROLE|INHERIT|LOGIN|REPLICATION|BYPASSRLS)\z/

      # Returns the trimmed output (tuples only, "|"-separated). vars become psql
      # variables: write :'name' for a literal, :"name" for an identifier, and psql quotes them.
      def psql(sql, db: nil, vars: {})
        # From /: postgres can't enter a 750 home and psql would warn into the output.
        within("/") { sudo("-u postgres #{psql_command(sql, db: db, vars: vars)}") }.strip
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
        psql(sql, vars: { name: name, password: password }.compact)
        created
      end

      # :missing, :offline or :online, from pg_lsclusters (postgresql-common).
      def pg_cluster_status(version, cluster = "main")
        clusters = JSON.parse(run("pg_lsclusters -js 2>/dev/null || echo '[]'"))
        found    = clusters.find { |c| c["version"].to_s == version.to_s && c["cluster"] == cluster }
        return :missing unless found

        found["running"] == 1 ? :online : :offline
      end

      def pg_ready?
        run("pg_isready -q && echo yes || echo no").strip == "yes"
      end

      def pg_wait_ready(timeout: 30)
        deadline = Time.now + timeout
        until pg_ready?
          raise Herd::CommandError, "postgresql not accepting connections after #{timeout}s" if Time.now > deadline

          sleep 1
        end
      end

      private

      # SQL goes through a quoted heredoc, so the shell never touches it;
      # only the -v values need shell escaping.
      def psql_command(sql, db:, vars:)
        flags = ["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
        flags.push("-d", db.to_s) if db
        vars.each { |key, value| flags.push("-v", "#{key}=#{value}") }

        "psql #{flags.shelljoin} <<'HERD_SQL'\n#{sql}\nHERD_SQL"
      end

      def pg_role_attribute(attribute)
        attribute = attribute.to_s.upcase
        raise ArgumentError, "pg_role: unknown attribute #{attribute}" unless attribute.match?(ROLE_ATTRIBUTE)

        attribute
      end
    end
  end
end
