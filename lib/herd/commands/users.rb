# frozen_string_literal: true

module Herd
  module Commands
    module Users
      def user_exists?(username)
        command_success?("id -- #{shell_args(username)} >/dev/null 2>&1")
      end

      def user_create(username, shell: "/bin/bash", groups: [])
        if user_exists?(username)
          info("user #{username} already exists, skipping")
          return
        end

        sudo("useradd -m -s #{shell_args(shell)} -- #{shell_args(username)}")
        groups.each { |g| user_add_to_group(username, g) }
        info("user #{username} created")
      end

      def user_add_to_group(username, group)
        sudo("usermod -aG #{shell_args(group)} -- #{shell_args(username)}")
      end

      # The "user:password" line reaches chpasswd through an uploaded file, not argv or a
      # heredoc, and the command is logged as sensitive.
      def change_password(username, new_password)
        if username.include?(":") || "#{username}#{new_password}".include?("\n")
          raise ArgumentError, "change_password: chpasswd can't take ':' in a user name or a newline"
        end

        secret(new_password)
        with_upload("#{username}:#{new_password}\n", sensitive: true) do |file|
          sudo("chpasswd < #{file.shell_path}", sensitive: true)
        end
        host.password = new_password if username == host.user
      end
    end
  end
end
