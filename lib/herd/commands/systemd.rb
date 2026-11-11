# frozen_string_literal: true

module Herd
  module Commands
    module Systemd
      # Unit types systemd knows; a name ending in one of these keeps its suffix.
      UNIT_TYPES = %w[service socket timer target path mount automount swap slice scope device].freeze
      # Characters systemd allows in unit names.
      UNIT_NAME = /\A[A-Za-z0-9:_.\\@-]+\z/
      USER_NAME = /\A[a-z_][a-z0-9_-]*\$?\z/
      ACTION    = /\A[a-z][a-z-]*\z/

      # The full unit name: "puma" and "worker@reid.1" get ".service", "backup.timer" and
      # "puma.service" are kept. The one place names are normalized, so systemctl calls,
      # unit files and sudoers rules agree.
      def self.unit_name(name)
        name = name.to_s
        raise ArgumentError, "systemd: invalid unit name #{name.inspect}" unless name.match?(UNIT_NAME)

        UNIT_TYPES.include?(name[/\.([a-z]+)\z/, 1]) ? name : "#{name}.service"
      end

      def systemctl_enable(service, now: false)
        systemctl("enable", *("--now" if now), service)
      end

      def systemctl_disable(service, now: false)
        systemctl("disable", *("--now" if now), service)
      end

      def systemctl_start(service)
        systemctl("start", service)
      end

      def systemctl_stop(service)
        systemctl("stop", service)
      end

      def systemctl_restart(service)
        systemctl("restart", service)
      end

      def systemctl_reload(service)
        systemctl("reload", service)
      end

      def systemctl_daemon_reload
        sudo "systemctl daemon-reload"
      end

      # Daemon-reloads only on change; returns whether the unit changed, restarting is up to the caller.
      # Templates ("app@") need enable: false.
      def systemd_unit(name, content, enable: true)
        unit    = Systemd.unit_name(name)
        changed = file("/etc/systemd/system/#{unit}", "root", "root", content: content, mode: 644)

        systemctl_daemon_reload if changed
        systemctl_enable(unit) if enable
        changed
      end

      def service_active?(service)
        systemctl_state("is-active", service) == "active"
      end

      def service_enabled?(service)
        systemctl_state("is-enabled", service) == "enabled"
      end

      # Grants a user NOPASSWD sudo for the given systemctl actions on each unit.
      # The file is checked with visudo before it replaces the old one, so a rejected
      # rule never lands in /etc/sudoers.d (where it would break sudo for everyone).
      # Returns true if the file changed.
      #
      # sudoers_path is overwritten wholesale on every call — it's fully
      # declarative, not additive. Two calls with different `units` pointed at
      # the SAME sudoers_path will not merge; the second call's content wins
      # and the first grant is lost. Give each independently-managed set of
      # units its own sudoers_path (e.g. one per app/component), the way
      # /etc/sudoers.d/ is conventionally split into numbered files.
      def systemd_allow_actions(sudoers_path, user:, units:, actions: %w[start stop restart status])
        raise ArgumentError, "systemd_allow_actions: invalid user #{user.inspect}" unless user.to_s.match?(USER_NAME)

        lines = Array(units).flat_map do |unit|
          actions.map do |action|
            raise ArgumentError, "systemd_allow_actions: invalid action #{action.inspect}" unless action.match?(ACTION)

            "#{user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl #{action} #{sudoers_escape(Systemd.unit_name(unit))}"
          end
        end

        content = "#{Herd::MANAGED_HEADER}\n\n#{lines.join("\n")}\n"
        install_file(sudoers_path, content, owner: "root", group: "root", mode: 440, sudo: true,
                                            validate: "visudo -cf %{staged}")
      end

      private

      def systemctl(action, *flags_and_unit)
        *flags, unit = flags_and_unit
        sudo("systemctl #{shell_args(action, *flags, Systemd.unit_name(unit))}")
      end

      # systemctl is-active/is-enabled print the state and exit nonzero for anything but
      # active/enabled, so the exit status isn't an error here.
      def systemctl_state(query, service)
        run_result("systemctl #{shell_args(query, Systemd.unit_name(service))}", pty: false).stdout.strip
      end

      # In a sudoers command line these characters must be backslash-escaped.
      def sudoers_escape(arg)
        arg.gsub(/[\\:,=]/) { "\\#{it}" }
      end
    end
  end
end
