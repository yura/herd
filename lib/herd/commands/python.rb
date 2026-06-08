# frozen_string_literal: true

module Herd
  module Commands
    # Commands for python environment
    module Python
      def install_uv(upgrade: false)
        if upgrade && file_exists?("~/.local/bin/uv")
          upgrade_uv
        else
          run("curl -LsSf https://astral.sh/uv/install.sh | sh")
        end
      end

      def upgrade_uv
        run("~/.local/bin/uv self update")
      end
    end
  end
end
