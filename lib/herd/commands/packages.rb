# frozen_string_literal: true

module Herd
  module Commands
    # Working with package managers, like apt for Ubuntu
    module Packages
      def install_packages(packages)
        packages = [packages].flatten.join(" ")
        echo %(-e '#{password}\n' | sudo -S apt install -qq -y #{packages})
      end
    end
  end
end
