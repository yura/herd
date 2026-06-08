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
    end
  end
end
