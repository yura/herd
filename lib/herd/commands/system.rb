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
    end
  end
end
