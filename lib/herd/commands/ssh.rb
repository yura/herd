# frozen_string_literal: true

module Herd
  module Commands
    module Ssh
      def ssh_keygen(key_path, comment: "#{host.user}@#{host.host}")
        unless file_exists?("#{key_path}.pub")
          run("ssh-keygen -o -a 100 -t ed25519 -f #{key_path} -N '' -C '#{comment}' -q")
          info("ssh key generated: #{key_path}")
        end

        run("cat #{key_path}.pub").chomp
      end

      def ssh_set_permissions
        ssh_chmod("~/.ssh",                 700)
        ssh_chmod("~/.ssh/config",          600) if file_exists?("~/.ssh/config")
        ssh_chmod("~/.ssh/authorized_keys", 600) if file_exists?("~/.ssh/authorized_keys")
        ssh_chmod("~/.ssh/known_hosts",     600) if file_exists?("~/.ssh/known_hosts")
        run("find ~/.ssh -name '*.pub' ! -perm 644 -exec chmod 644 {} \\;")
        run("find ~/.ssh -name 'id_*' ! -name '*.pub' ! -perm 600 -exec chmod 600 {} \\;")
      end

      private

      def ssh_chmod(path, mode)
        current = run("stat -c %a #{path}").strip
        run("chmod #{mode} #{path}") unless current == mode.to_s
      end
    end
  end
end
