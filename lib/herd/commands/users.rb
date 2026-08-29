# frozen_string_literal: true

module Herd
  module Commands
    module Users
      def user_exists?(username)
        run("id #{username} 2>/dev/null && echo yes || echo no").strip == "yes"
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
        with_env("HERD_PASS" => new_password) do
          run(%(echo "#{username}:$HERD_PASS" | sudo -p '#{Herd::Session::SUDO_PROMPT}' chpasswd))
        end
        host.password = new_password if username == host.user
      end
    end
  end
end
