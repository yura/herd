# frozen_string_literal: true

module Herd
  module Commands
    module Apt
      def apt_update
        sudo("apt update -qq")
      end

      def apt_upgrade
        sudo("DEBIAN_FRONTEND=noninteractive apt upgrade -qq -y")
      end

      def apt_install(*packages, confnew: false)
        opts = confnew ? "-o Dpkg::Options::='--force-confnew'" : nil
        parts = ["DEBIAN_FRONTEND=noninteractive apt install -qq -y", opts, packages.flatten.join(" ")].compact
        sudo(parts.join(" "))
      end

      def apt_remove(*packages)
        sudo("apt remove -qq -y #{packages.flatten.join(" ")}")
      end

      def apt_autoremove
        sudo("apt autoremove -qq -y")
      end

      def apt_installed?(package)
        run("dpkg -l #{package} 2>/dev/null | grep -q '^ii' && echo yes || echo no").strip == "yes"
      end

      # Returns the installed version string, or nil if the package isn't installed.
      def apt_version(package)
        version = run("dpkg-query -W -f='${Version}' #{package} 2>/dev/null || true").strip
        version.empty? ? nil : version
      end

      # Adds a third-party apt repository: fetches its signing key (re-fetching
      # if it's missing or its fingerprint doesn't match, when one is given)
      # and writes the sources.list.d entry.
      #
      # `fingerprint:` verifies the key after fetching and raises if it doesn't
      # match — pass one whenever the vendor publishes it. Without it, the key
      # is trusted on first download, same as most vendors' own install docs.
      #
      # `dearmor: true` for keys distributed as ASCII-armored text that need
      # converting to a binary keyring; the default writes the fetched key as-is.
      def apt_add_repo(sources_path, sources_line, keyring_path:, keyring_url:, fingerprint: nil, dearmor: false)
        unless apt_repo_key_valid?(keyring_path, fingerprint)
          if dearmor
            sudo(%(bash -c 'curl -fsSL #{keyring_url} | gpg --dearmor > #{keyring_path}'))
          else
            sudo("curl -fsSL -o #{keyring_path} #{keyring_url}")
          end

          apt_verify_repo_key!(keyring_path, fingerprint) if fingerprint

          # apt's sandboxed _apt user needs to read the keyring during update/install.
          file_permissions(keyring_path, 644)
        end

        expect_file_content_equals(sources_path, "#{sources_line}\n")
        apt_update
      end

      private

      def apt_repo_key_valid?(keyring_path, fingerprint)
        return false unless file_exists?(keyring_path)
        return true unless fingerprint

        apt_repo_key_fingerprint(keyring_path).include?(fingerprint)
      end

      def apt_verify_repo_key!(keyring_path, fingerprint)
        return if apt_repo_key_fingerprint(keyring_path).include?(fingerprint)

        raise Herd::CommandError, "apt_add_repo: key at #{keyring_path} does not match expected fingerprint #{fingerprint}"
      end

      def apt_repo_key_fingerprint(keyring_path)
        run("gpg --dry-run --quiet --no-keyring --import --import-options import-show #{keyring_path} 2>/dev/null || true")
      end
    end
  end
end
