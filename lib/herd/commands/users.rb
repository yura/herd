# frozen_string_literal: true

require "shellwords"

module Herd
  module Commands
    module Users
      def user_exists?(username)
        run("id #{username} >/dev/null 2>&1 && echo yes || echo no").strip == "yes"
      end

      def user_create(username, shell: "/bin/bash", groups: [])
        if user_exists?(username)
          info("user #{username} already exists, skipping")
          return
        end

        sudo("useradd -m -s #{shell} #{username}")
        groups.each { |g| user_add_to_group(username, g) }
        info("user #{username} created")
      end

      def user_add_to_group(username, group)
        sudo("usermod -aG #{group} #{username}")
      end

      def change_password(username, new_password)
        # printf is a builtin, so the password stays out of ps; shellescape keeps spaces and $() literal.
        line = "#{username}:#{new_password}".shellescape
        run(%(printf '%s\\n' #{line} | sudo -p '#{Herd::Session::SUDO_PROMPT}' chpasswd))
        host.password = new_password if username == host.user
      end
    end
  end
end
