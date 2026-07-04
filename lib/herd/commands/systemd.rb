# frozen_string_literal: true

module Herd
  module Commands
    module Systemd
      def systemctl_enable(service, now: false)
        sudo "systemctl enable#{" --now" if now} #{service}"
      end

      def systemctl_disable(service, now: false)
        sudo "systemctl disable#{" --now" if now} #{service}"
      end

      def systemctl_start(service)
        sudo "systemctl start #{service}"
      end

      def systemctl_stop(service)
        sudo "systemctl stop #{service}"
      end

      def systemctl_restart(service)
        sudo "systemctl restart #{service}"
      end

      def systemctl_reload(service)
        sudo "systemctl reload #{service}"
      end

      def systemctl_daemon_reload
        sudo "systemctl daemon-reload"
      end

      def service_active?(service)
        run("systemctl is-active #{service} || true").strip == "active"
      end

      def service_enabled?(service)
        run("systemctl is-enabled #{service} || true").strip == "enabled"
      end

      # Grants a user NOPASSWD sudo for the given systemctl actions on each unit.
      #
      # sudoers_path is overwritten wholesale on every call — it's fully
      # declarative, not additive. Two calls with different `units` pointed at
      # the SAME sudoers_path will not merge; the second call's content wins
      # and the first grant is lost. Give each independently-managed set of
      # units its own sudoers_path (e.g. one per app/component), the way
      # /etc/sudoers.d/ is conventionally split into numbered files.
      def systemd_allow_actions(sudoers_path, user:, units:, actions: %w[start stop restart status])
        lines = Array(units).flat_map do |unit|
          actions.map { |action| "#{user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl #{action} #{unit}.service" }
        end

        content = "# Managed by Herd. Do not edit manually.\n\n#{lines.join("\n")}\n"
        expect_file_content_equals(sudoers_path, content)
        file_permissions(sudoers_path, 440)
      end
    end
  end
end
