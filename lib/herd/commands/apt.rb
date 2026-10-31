# frozen_string_literal: true

module Herd
  module Commands
    module Apt
      # Package names as apt takes them: name, name=version, name:arch, name/release.
      # Anything else (a leading "-", spaces, shell syntax) is refused before it reaches apt.
      PACKAGE_NAME = %r{\A[a-z0-9][a-z0-9+.-]*(?::[a-z0-9-]+)?(?:=[\w.+:~-]+|/[\w.-]+)?\z}i
      # v4 keys have 40 hex digits, v5 keys 64.
      FINGERPRINT = /\A(?:\h{40}|\h{64})\z/

      def apt_update
        sudo("apt update -qq")
      end

      def apt_upgrade
        sudo("DEBIAN_FRONTEND=noninteractive apt upgrade -qq -y")
      end

      # packages are names (see PACKAGE_NAME) or paths to local .deb files; apt reads an
      # argument as a file only when it contains "/", so write "./pkg.deb", not "pkg.deb".
      def apt_install(*packages, confnew: false)
        opts = confnew ? shell_args("-o", "Dpkg::Options::=--force-confnew") : nil
        args = packages.flatten.map(&:to_s).map { |p| apt_deb?(p) ? shell_path(p) : shell_args(apt_packages([p])) }
        sudo(["DEBIAN_FRONTEND=noninteractive apt install -qq -y", opts, *args].compact.join(" "))
      end

      def apt_remove(*packages)
        sudo("apt remove -qq -y #{shell_args(apt_packages(packages))}")
      end

      def apt_autoremove
        sudo("apt autoremove -qq -y")
      end

      # True if the package is installed (dpkg status "... installed"); a removed package
      # whose config files remain is not.
      def apt_installed?(package)
        apt_query(package, "${Status}")&.split&.last == "installed"
      end

      # Returns the installed version string, or nil if the package isn't installed.
      def apt_version(package)
        apt_installed?(package) ? apt_query(package, "${Version}") : nil
      end

      # Adds a third-party apt repository: makes sure its signing key is in place and
      # writes the sources.list.d entry.
      #
      # `fingerprint:` (one or several) pins the keys: the keyring must hold exactly these
      # primary keys, no more — apt trusts every key in a signed-by keyring. Pass it whenever
      # the vendor publishes one. Without it, the key is trusted on first download, same as
      # most vendors' own install docs.
      #
      # The key is downloaded and checked in a temporary file; the keyring is replaced only
      # after the check passes, so a bad download never breaks a working configuration.
      #
      # `dearmor: true` for keys distributed as ASCII-armored text that need converting to a
      # binary keyring; the default writes the fetched key as-is.
      def apt_add_repo(sources_path, sources_line, keyring_path:, keyring_url:, fingerprint: nil, dearmor: false)
        expected = fingerprint && apt_expected_fingerprints(fingerprint)
        apt_fetch_keyring(keyring_path, keyring_url, expected, dearmor: dearmor) unless apt_keyring_ok?(keyring_path,
                                                                                                        expected)

        install_file(sources_path, "#{sources_line}\n", owner: "root", group: "root", mode: 644, sudo: true)
        apt_update
      end

      private

      # The field of package's dpkg record, or nil if dpkg doesn't know the package.
      def apt_query(package, format)
        result = run_result("dpkg-query -W -f=#{shell_args(format)} #{shell_args(apt_packages([package]))}", pty: false)
        # dpkg-query exits 1 for a package it doesn't know; anything else is an error.
        raise Herd::CommandError, "dpkg-query: #{result.stderr.strip}" unless [0, 1].include?(result.exit_code)

        result.success? ? result.stdout.strip : nil
      end

      def apt_deb?(package) = package.include?("/") && package.end_with?(".deb")

      def apt_packages(packages)
        packages.flatten.map(&:to_s).each do |package|
          raise ArgumentError, "apt: invalid package name #{package.inspect}" unless package.match?(PACKAGE_NAME)
        end
      end

      def apt_expected_fingerprints(fingerprint)
        expected = Array(fingerprint).map { |f| f.to_s.upcase.delete(" ") }
        if expected.empty? || !expected.all? { |f| f.match?(FINGERPRINT) }
          raise ArgumentError, "apt_add_repo: fingerprint must be 40 or 64 hex digits, got #{fingerprint.inspect}"
        end

        expected.uniq.sort
      end

      # True if the keyring is a regular file holding at least one key (exactly the expected
      # ones, when given). A wrong owner or mode is fixed here without downloading the key again.
      def apt_keyring_ok?(keyring_path, expected)
        info = file_info(keyring_path, sudo: true)
        return false unless info&.type == "regular file"

        fingerprints = apt_key_fingerprints(read_bytes(keyring_path, sudo: true))
        return false if fingerprints.nil? || fingerprints.empty?
        return false if expected && fingerprints != expected

        # apt's sandboxed _apt user needs to read the keyring during update/install.
        file_user_and_group(keyring_path, "root", "root") unless info.user == "root" && info.group == "root"
        file_permissions(keyring_path, 644) unless info.mode == "644"
        true
      end

      def apt_fetch_keyring(keyring_path, keyring_url, expected, dearmor:)
        key          = apt_download_key(keyring_url, dearmor: dearmor)
        fingerprints = apt_key_fingerprints(key)
        if fingerprints.nil? || fingerprints.empty?
          raise Herd::CommandError,
                "apt_add_repo: #{keyring_url} is not an OpenPGP key"
        end
        if expected && fingerprints != expected
          raise Herd::CommandError, "apt_add_repo: key from #{keyring_url} has fingerprints #{fingerprints.join(", ")}, " \
                                    "expected exactly #{expected.join(", ")}"
        end

        install_file(keyring_path, key, owner: "root", group: "root", mode: 644, sudo: true)
      end

      # The key's bytes, downloaded (and dearmored) on the remote host into a temporary file.
      def apt_download_key(url, dearmor:)
        script = <<~SH
          set -eu
          t=$(mktemp -d)
          trap 'rm -rf -- "$t"' EXIT
          curl -fsSL -o "$t/key" -- "$1"
          if [ "$2" = 1 ]; then
            gpg --homedir "$t" --batch --dearmor -o "$t/key.gpg" -- "$t/key"
            cat -- "$t/key.gpg"
          else
            cat -- "$t/key"
          fi
        SH
        run("sh -c #{script.shellescape} _ #{shell_args(url, dearmor ? 1 : 0)}", pty: false).b
      end

      # Sorted fingerprints of the primary keys in key (bytes); subkeys don't count.
      # nil when gpg can't read it as keys. gpg runs with a throwaway homedir: without one
      # it would create ~/.gnupg, and older versions truncate the listing of multi-key files.
      def apt_key_fingerprints(key)
        script = <<~SH
          set -eu
          d=$(mktemp -d)
          trap 'rm -rf -- "$d"' EXIT
          gpg --homedir "$d" --batch --with-colons --show-keys -- "$1"
        SH
        result = with_upload(key) { |file| run_result("sh -c #{script.shellescape} _ #{file.shell_path}", pty: false) }
        return unless result.success?

        apt_primary_fingerprints(result.stdout)
      end

      # Parses `gpg --with-colons` output: the fpr record right after a pub record is the
      # primary key's fingerprint (field 10). A user ID that merely contains a fingerprint
      # is a uid record and never counts.
      def apt_primary_fingerprints(colons)
        previous = nil
        colons.each_line.with_object([]) do |line, found|
          fields = line.chomp.split(":")
          found << fields[9].upcase if fields[0] == "fpr" && previous == "pub"
          previous = fields[0]
        end.uniq.sort
      end
    end
  end
end
