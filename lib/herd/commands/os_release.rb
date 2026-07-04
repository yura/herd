# frozen_string_literal: true

module Herd
  module Commands
    # Parses /etc/os-release — present on virtually every modern Linux distro —
    # and caches it for the lifetime of the SSH connection.
    module OsRelease
      def os_release
        @os_release ||= fetch_os_release
      end

      # Bypasses the cache — useful after something on the host may have changed
      # the OS version (e.g. a distro upgrade) within the same connection.
      def refresh_os_release
        @os_release = fetch_os_release
      end

      def os_id       = os_release["ID"]
      def os_version  = os_release["VERSION_ID"]
      def os_codename = os_release["VERSION_CODENAME"]

      def ubuntu?
        os_id == "ubuntu"
      end

      # Accepts any Gem::Requirement operator(s), e.g. ubuntu_version?(">= 24.04", "< 26.04")
      def ubuntu_version?(*requirements)
        ubuntu? && Gem::Requirement.new(*requirements).satisfied_by?(Gem::Version.new(os_version))
      end

      def ubuntu_version_below?(version)
        ubuntu_version?("< #{version}")
      end

      private

      def fetch_os_release
        run("cat /etc/os-release").each_line.each_with_object({}) do |line, hash|
          key, _, value = line.strip.partition("=")
          hash[key] = value.delete_prefix('"').delete_suffix('"') unless key.empty?
        end
      end
    end
  end
end
