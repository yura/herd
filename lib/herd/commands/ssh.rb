# frozen_string_literal: true

require "json"
require "net/http"

module Herd
  module Commands
    module Ssh
      DEPLOY_KEYS_DIR  = "~/.ssh/deploy_keys"
      CONFIG_D_DIR     = "~/.ssh/config.d"
      KNOWN_HOSTS_DIR  = "~/.ssh/known_hosts.d"
      CONFIG_D_INCLUDE = "Include ~/.ssh/config.d/*.conf"
      GITHUB_META_URL  = "https://api.github.com/meta"
      GITHUB_META_LOCK = Mutex.new

      # Fetched once per process — every host thread shares the same answer.
      def self.github_ssh_keys
        GITHUB_META_LOCK.synchronize do
          @github_ssh_keys ||= begin
            response = Net::HTTP.get_response(URI(GITHUB_META_URL))
            unless response.is_a?(Net::HTTPSuccess)
              raise Herd::CommandError, "#{GITHUB_META_URL}: #{response.code} #{response.body}"
            end

            JSON.parse(response.body).fetch("ssh_keys")
          end
        end
      end

      def ssh_keygen(key_path, comment: "#{host.user}@#{host.host}")
        unless file_exists?("#{key_path}.pub")
          run("ssh-keygen -o -a 100 -t ed25519 -f #{key_path} -N '' -C '#{comment}' -q")
          info("ssh key generated: #{key_path}")
        end

        run("cat #{key_path}.pub").chomp
      end

      # A deploy key works for one repo only, hence a key per repo behind a "github-<name>"
      # alias (git@github-<name>:owner/repo.git). Returns the public key.
      def ssh_deploy_key(name, git_host: "github.com", known_hosts: nil,
                         comment: "#{name}@#{host.user}@#{host.host}")
        ssh_config_d_include
        run("mkdir -p -m 700 #{DEPLOY_KEYS_DIR} #{CONFIG_D_DIR} #{KNOWN_HOSTS_DIR}")

        key_path = "#{DEPLOY_KEYS_DIR}/#{name}_ed25519"
        pub_key  = ssh_keygen(key_path, comment: comment)

        known_hosts_path = "#{KNOWN_HOSTS_DIR}/#{git_host}"
        keys = known_hosts || ssh_known_host_keys(git_host)
        ssh_private_file(known_hosts_path, keys.map { |key| "#{git_host} #{key}" }.join("\n"))

        ssh_private_file("#{CONFIG_D_DIR}/#{name}.conf", ssh_alias_config(name, git_host, key_path, known_hosts_path))
        pub_key
      end

      def ssh_set_permissions
        ssh_chmod("~/.ssh",                 700)
        ssh_chmod("~/.ssh/config",          600) if file_exists?("~/.ssh/config")
        ssh_chmod("~/.ssh/authorized_keys", 600) if file_exists?("~/.ssh/authorized_keys")
        ssh_chmod("~/.ssh/known_hosts",     600) if file_exists?("~/.ssh/known_hosts")
        run("find ~/.ssh -name '*.pub' ! -perm 644 -exec chmod 644 {} \\;")
        run("find ~/.ssh -name 'id_*' ! -name '*.pub' ! -perm 600 -exec chmod 600 {} \\;")
        ssh_herd_dirs_permissions
      end

      private

      # The dirs ssh_deploy_key creates: 700, files inside 600 (public keys are handled above).
      # One round trip; missing dirs are skipped, a failing chmod raises.
      def ssh_herd_dirs_permissions
        dirs  = [DEPLOY_KEYS_DIR, CONFIG_D_DIR, KNOWN_HOSTS_DIR].join(" ")
        files = %(find "$d" -type f ! -name '*.pub' ! -perm 600 -exec chmod 600 {} +)
        run(%(for d in #{dirs}; do [ -d "$d" ] || continue; chmod 700 "$d" || exit 1; #{files} || exit 1; done))
      end

      def ssh_chmod(path, mode)
        current = run("stat -c %a #{path}").strip
        run("chmod #{mode} #{path}") unless current == mode.to_s
      end

      # Include must precede any Host block, hence prepend.
      def ssh_config_d_include
        return if file_contains?("~/.ssh/config", CONFIG_D_INCLUDE)

        prepend_to_file("~/.ssh/config", CONFIG_D_INCLUDE)
        ssh_chmod("~/.ssh/config", 600)
      end

      # Touched as the user first, so the write needs neither sudo nor chown.
      def ssh_private_file(path, content)
        run("touch #{path} && chmod 600 #{path}")
        expect_file_content_equals(path, content)
      end

      def ssh_alias_config(name, git_host, key_path, known_hosts_path)
        <<~CONF
          Host #{git_host.split(".").first}-#{name}
            HostName #{git_host}
            User git
            IdentitiesOnly yes
            IdentityFile #{key_path}
            UserKnownHostsFile #{known_hosts_path}
        CONF
      end

      def ssh_known_host_keys(git_host)
        return Herd::Commands::Ssh.github_ssh_keys if git_host == "github.com"

        raise ArgumentError, "ssh_deploy_key: pass known_hosts: for #{git_host}"
      end
    end
  end
end
