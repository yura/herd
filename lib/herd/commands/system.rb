# frozen_string_literal: true

module Herd
  module Commands
    module System
      HOSTNAME = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/i

      def set_hostname(hostname)
        raise ArgumentError, "set_hostname: invalid hostname #{hostname.inspect}" unless hostname.match?(HOSTNAME)

        current = run("hostname").chomp
        if current == hostname
          info("hostname already #{hostname}, skipping")
          return
        end

        sudo("hostnamectl set-hostname #{shell_args(hostname)}")

        if file_contains?("/etc/hosts", "127.0.1.1")
          replace_line_in_file("/etc/hosts", /^127\.0\.1\.1.*/, "127.0.1.1\t#{hostname}", sudo: true)
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
      # timedatectl works on any systemd host; /etc/timezone is Debian-only, kept as a fallback.
      def system_timezone
        run("timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone").strip
      end

      # Returns true if the timezone changed.
      def set_timezone(timezone)
        if system_timezone == timezone
          info("timezone already #{timezone}, skipping")
          return false
        end

        sudo("timedatectl set-timezone #{shell_args(timezone)}")
        info("timezone set to #{timezone}")
        true
      end

      # Returns true if locale-gen ran. locale -a lists "en_US.utf8" for "en_US.UTF-8",
      # so names compare without case and dashes.
      def locale_generate(locale)
        normalize = ->(name) { name.strip.downcase.delete("-") }
        if run("locale -a", pty: false).lines.map(&normalize).include?(normalize.call(locale))
          info("locale #{locale} already generated, skipping")
          return false
        end

        sudo("locale-gen #{shell_args(locale)}")
        info("locale #{locale} generated")
        true
      end

      # System LANG via localectl, and /etc/default/locale reduced to just that line.
      # Returns true if anything changed.
      def set_locale(locale)
        lang = "LANG=#{locale}"
        # localectl failing (no systemd) means the system locale isn't known to be set: set it.
        status = run_result("localectl status", pty: false)
        if status.success? && status.stdout.lines.grep(/System Locale/).join.include?(lang) &&
           file_exists?("/etc/default/locale") && read_file!("/etc/default/locale", sudo: true).strip == lang
          info("system locale already #{locale}, skipping")
          return false
        end

        sudo("localectl set-locale #{shell_args(lang)}")
        expect_file_content_equals("/etc/default/locale", "#{lang}\n")
        info("system locale set to #{locale}")
        true
      end
    end
  end
end
