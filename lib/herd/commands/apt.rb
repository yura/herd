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
        opts = confnew ? "-o Dpkg::Options::='--force-confnew'" : ""
        sudo("DEBIAN_FRONTEND=noninteractive apt install -qq -y #{opts} #{packages.flatten.join(' ')}".strip)
      end

      def apt_remove(*packages)
        sudo("apt remove -qq -y #{packages.flatten.join(' ')}")
      end

      def apt_autoremove
        sudo("apt autoremove -qq -y")
      end

      def apt_installed?(package)
        run("dpkg -l #{package} 2>/dev/null | grep -q '^ii' && echo yes || echo no").strip == "yes"
      end
    end
  end
end
