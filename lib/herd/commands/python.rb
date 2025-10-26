# frozen_string_literal: true

module Herd
  module Commands
    # Commands for python environment
    module Python
      def install_uv
        run("curl -LsSf https://astral.sh/uv/install.sh | sh")
      end
    end
  end
end
