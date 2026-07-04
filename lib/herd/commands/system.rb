# frozen_string_literal: true

module Herd
  module Commands
    module System
      def set_hostname(hostname)
        current = run("hostname").chomp
        if current == hostname
          info("hostname already #{hostname}, skipping")
          return
        end

        sudo("hostnamectl set-hostname #{hostname}")

        if file_contains?("/etc/hosts", "127.0.1.1")
          sudo("sed -i 's/^127\\.0\\.1\\.1.*/127.0.1.1\\t#{hostname}/' /etc/hosts")
        else
          ensure_line_in_file("/etc/hosts", "127.0.1.1\t#{hostname}", sudo: true)
        end

        info("hostname set to #{hostname}")
      end

      # Named system_timezone (not timezone) to avoid colliding with the very
      # common local variable name "timezone" in recipes. Not cached, unlike
      # os_release — recipes routinely change the timezone (timedatectl) within
      # a connection, and a stale cached value would silently mislead callers
      # later in the same run.
      def system_timezone
        run("cat /etc/timezone").strip
      end
    end
  end
end
