# frozen_string_literal: true

require "csv"

module Herd
  # Builds Herd::Host instances from a CSV file.
  class HostsLoader
    def initialize(path:, default_user:, default_port:, default_timeout:)
      @path = path
      @default_user = default_user
      @default_port = default_port
      @default_timeout = default_timeout
    end

    def load
      hosts = CSV.foreach(path, headers: true).map { |row| build_host(row) }
      raise ArgumentError, "No hosts found in #{path}" if hosts.empty?

      hosts
    end

    private

    attr_reader :path, :default_user, :default_port, :default_timeout

    def build_host(row)
      host = presence(row["host"])
      raise ArgumentError, "CSV row missing host" if host.nil?

      Herd::Host.new(host, user_for(row), **host_options(row))
    end

    def user_for(row)
      presence(row["user"]) || default_user
    end

    def host_options(row)
      {
        port: integer_or_default(row["port"], default_port),
        timeout: integer_or_default(row["timeout"], default_timeout),
        password: presence(row["password"]),
        private_key_path: presence(row["private_key"]) || presence(row["key"]),
        alias_name: presence(row["alias"])
      }.compact
    end

    def integer_or_default(value, fallback)
      numeric = presence(value)
      Integer(numeric || fallback)
    end

    def presence(value)
      stripped = value&.strip
      stripped unless stripped.nil? || stripped.empty?
    end
  end
end
