# frozen_string_literal: true

module Herd
  module Commands
    # Parses /etc/os-release — present on virtually every modern Linux distro —
    # and caches it for the lifetime of the SSH connection.
    module OsRelease
      def os_release
        @os_release ||= run("cat /etc/os-release").each_line.each_with_object({}) do |line, hash|
          key, _, value = line.strip.partition("=")
          hash[key] = value.delete_prefix('"').delete_suffix('"') unless key.empty?
        end
      end

      def os_id       = os_release["ID"]
      def os_version  = os_release["VERSION_ID"]
      def os_codename = os_release["VERSION_CODENAME"]

      def ubuntu?
        os_id == "ubuntu"
      end

      def ubuntu_version_below?(version)
        ubuntu? && Gem::Version.new(os_version) < Gem::Version.new(version)
      end
    end
  end
end
