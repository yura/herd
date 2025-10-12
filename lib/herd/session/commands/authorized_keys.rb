# frozen_string_literal: true

module Herd
  module SessionCommands
    # Commands for inspecting and managing authorized SSH keys.
    module AuthorizedKeys
      def authorized_keys
        cat("~/.ssh/authorized_keys")&.chomp&.split("\n") || []
      end

      def add_authorized_key(key)
        touch("~/.ssh/authorized_keys")
        chmod("600 ~/.ssh/authorized_keys")
        echo("'#{key}' >> ~/.ssh/authorized_keys")
      end
    end
  end
end
