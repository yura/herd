# frozen_string_literal: true

module Herd
  module Commands
    # Abstraction over OS package managers — delegates to apt, yum, etc. based on the detected system
    module Packages
      def package_install(*packages, **opts)
        case package_manager
        when :apt then apt_install(*packages, **opts)
        else raise "unsupported package manager: #{package_manager}"
        end
      end

      def package_update
        case package_manager
        when :apt then apt_update
        else raise "unsupported package manager: #{package_manager}"
        end
      end

      def package_installed?(package)
        case package_manager
        when :apt then apt_installed?(package)
        else raise "unsupported package manager: #{package_manager}"
        end
      end

      private

      def package_manager
        @package_manager ||= begin
          out = run("which apt-get > /dev/null 2>&1 && echo apt || which yum > /dev/null 2>&1 && echo yum || echo unknown").strip
          out.to_sym
        end
      end
    end
  end
end
