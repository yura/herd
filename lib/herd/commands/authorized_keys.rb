# frozen_string_literal: true

module Herd
  module Commands
    # Commands for inspecting and managing authorized SSH keys.
    module AuthorizedKeys
      AUTHORIZED_KEYS_FILE = "~/.ssh/authorized_keys"

      def authorized_keys_contains_exactly(required_keys)
        required_keys = [required_keys].flatten
        diff = keys_diff(authorized_keys, required_keys)
        self.authorized_keys = required_keys

        diff
      end

      def authorized_keys
        read_file(AUTHORIZED_KEYS_FILE)&.split(/\r\n|\r|\n/) || []
      end

      def authorized_keys=(keys)
        touch(AUTHORIZED_KEYS_FILE)
        write_to_file(AUTHORIZED_KEYS_FILE, [keys].flatten.join("\n"))
        file_permissions(AUTHORIZED_KEYS_FILE, 600)
      end

      def add_authorized_key(key)
        touch(AUTHORIZED_KEYS_FILE)
        append_to_file(AUTHORIZED_KEYS_FILE, key)
        file_permissions(AUTHORIZED_KEYS_FILE, 600)
      end

      private

      def keys_diff(actual_keys, required_keys)
        result = Hash.new { |h, k| h[k] = [] }
        actual_keys.each do |actual_key|
          if required_keys.include?(actual_key)
            result[:existing] << actual_key
          else
            result[:obsolete] << actual_key
          end
        end
        result.merge({ added: required_keys - actual_keys })
      end
    end
  end
end
