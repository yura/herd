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
      SSH_DIR          = "~/.ssh"
      SSHD_CONFIG      = "/etc/ssh/sshd_config"
      SSHD_CONFIG_D    = "/etc/ssh/sshd_config.d/*.conf"
      ACCEPT_ENV       = /^([ \t]*)(AcceptEnv\b)/i
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

      # Creates the key's directory (mode 700) if a fresh user doesn't have it yet.
      def ssh_keygen(key_path, comment: "#{host.user}@#{host.host}")
        unless file_exists?("#{key_path}.pub")
          run("mkdir -p -m 700 -- #{shell_path(File.dirname(key_path))}")
          run("ssh-keygen -o -a 100 -t ed25519 -f #{shell_path(key_path)} -N '' -C #{shell_args(comment)} -q")
          info("ssh key generated: #{key_path}")
        end

        read_file("#{key_path}.pub")
      end

      # A deploy key works for one repo only, hence a key per repo behind a "github-<name>"
      # alias (git@github-<name>:owner/repo.git). Returns the public key.
      def ssh_deploy_key(name, git_host: "github.com", known_hosts: nil,
                         comment: "#{name}@#{host.user}@#{host.host}")
        raise ArgumentError, "ssh_deploy_key: invalid name #{name.inspect}" unless name.to_s.match?(/\A[\w.-]+\z/)
        unless git_host.match?(/\A[\w.-]+\z/)
          raise ArgumentError,
                "ssh_deploy_key: invalid git host #{git_host.inspect}"
        end

        # A fresh user has no ~/.ssh: create it before anything goes into it.
        run("mkdir -p -m 700 -- #{[SSH_DIR, DEPLOY_KEYS_DIR, CONFIG_D_DIR, KNOWN_HOSTS_DIR].map do
          shell_path(it)
        end.join(" ")}")
        ssh_config_d_include

        key_path = "#{DEPLOY_KEYS_DIR}/#{name}_ed25519"
        pub_key  = ssh_keygen(key_path, comment: comment)

        known_hosts_path = "#{KNOWN_HOSTS_DIR}/#{git_host}"
        keys = known_hosts || ssh_known_host_keys(git_host)
        ssh_private_file(known_hosts_path, keys.map { |key| "#{git_host} #{key}" }.join("\n"))

        ssh_private_file("#{CONFIG_D_DIR}/#{name}.conf", ssh_alias_config(name, git_host, key_path, known_hosts_path))
        pub_key
      end

      # Stops sshd taking the client's LANG/LC_*: a Mac sends e.g. LC_CTYPE=UTF-8, unknown
      # on Linux, which breaks locale-sensitive tools. Returns true if the config changed.
      #
      # Comments out every AcceptEnv line (indented ones too) in sshd_config and
      # sshd_config.d/*.conf, keeping a copy of each file it changes, then checks the
      # whole config with sshd -t. If anything fails the copies are put back, so a
      # rejected config never stays on disk (where it could stop sshd after a reboot).
      # AcceptEnv set in a file Included from elsewhere isn't edited: the final sshd -T
      # check finds it and raises.
      def sshd_disable_accept_env
        files   = [SSHD_CONFIG, *glob(SSHD_CONFIG_D, sudo: true)]
        changes = files.filter_map do |path|
          content = read_bytes(path, sudo: true).force_encoding(Encoding::UTF_8)
          edited  = content.gsub(ACCEPT_ENV) { "#{Regexp.last_match(1)}##{Regexp.last_match(2)}" }
          [path, edited] if edited != content
        end
        if changes.empty?
          # Nothing to edit here, but an AcceptEnv Included from elsewhere may still be in effect.
          sshd_refuse_accept_env!
          return false
        end

        sshd_install_validated(changes)
        systemctl_reload("ssh")
        sshd_refuse_accept_env!
        true
      end

      # Validates the config first: reloading a broken one can lock you out.
      # The service is "ssh" on Ubuntu, not "sshd".
      def sshd_reload
        sudo("sshd -t")
        systemctl_reload("ssh")
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
        current = run("stat -c %a -- #{shell_path(path)}").strip
        run("chmod -- #{mode} #{shell_path(path)}") unless current == mode.to_s
      end

      # Include must precede any Host block, hence prepend.
      def ssh_config_d_include
        return if file_contains?("~/.ssh/config", CONFIG_D_INCLUDE)

        prepend_to_file("~/.ssh/config", CONFIG_D_INCLUDE)
        ssh_chmod("~/.ssh/config", 600)
      end

      # The SSH user's own file, mode 600 from the moment it appears.
      def ssh_private_file(path, content)
        install_file(path, content, mode: 600)
      end

      # Backs up each file, installs the edited content, then runs sshd -t on the whole
      # config. Any failure restores every file from its backup, newest first.
      def sshd_install_validated(changes)
        installed = []
        changes.each do |path, content|
          sudo("cp -p -- #{shell_path(path)} #{shell_path("#{path}.herd-bak")}")
          installed << path
          install_file(path, content, sudo: true)
        end
        sudo("sshd -t")
        validated = true
      ensure
        # In ensure with a flag rather than in rescue: an Interrupt midway restores too.
        sshd_restore(installed) unless validated
      end

      def sshd_restore(paths)
        paths.reverse_each do |path|
          sudo("mv -f -- #{shell_path("#{path}.herd-bak")} #{shell_path(path)}")
        rescue StandardError => e
          info("could not restore #{path} from #{path}.herd-bak: #{e.message}")
        end
      end

      # sshd -T prints the effective config; any acceptenv left means one we couldn't edit.
      def sshd_refuse_accept_env!
        left = sudo("sshd -T").lines.grep(/\Aacceptenv /i).map(&:strip)
        return if left.empty?

        raise Herd::CommandError, "sshd still accepts #{left.join(", ")}: set outside sshd_config and " \
                                  "sshd_config.d, edit it by hand"
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
