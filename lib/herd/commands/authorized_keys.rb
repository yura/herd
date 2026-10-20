# frozen_string_literal: true

module Herd
  module Commands
    # Commands for inspecting and managing authorized SSH keys.
    module AuthorizedKeys
      AUTHORIZED_KEYS_FILE = "~/.ssh/authorized_keys"

      # Makes authorized_keys exactly these keys under a managed header. Keys not in the list
      # raise unless remove_unknown: true — one may be someone's only way in. Returns true if rewritten.
      def authorized_keys_sync(keys, remove_unknown: false)
        lines   = authorized_keys
        current = lines.reject { |line| line.start_with?("#") || line.strip.empty? }
        unknown = current - keys
        unless unknown.empty? || remove_unknown
          raise Herd::CommandError, "unknown keys in authorized_keys:\n#{unknown.join("\n")}"
        end

        changed = current != keys || lines.first != Herd::MANAGED_HEADER
        if changed
          self.authorized_keys = [Herd::MANAGED_HEADER] + keys
          info("authorized_keys updated: #{keys.count} keys")
        else
          info("authorized_keys already up to date, skipping")
        end

        ssh_set_permissions
        changed
      end

      def authorized_keys_contains_exactly(required_keys)
        required_keys = [required_keys].flatten
        diff = keys_diff(authorized_keys, required_keys)
        self.authorized_keys = required_keys

        diff
      end

      def authorized_keys
        return [] unless file_exists?(AUTHORIZED_KEYS_FILE)

        read_file(AUTHORIZED_KEYS_FILE)&.split(/\r\n|\r|\n/) || []
      end

      def authorized_keys=(keys)
        run("mkdir -p ~/.ssh")
        file_permissions("~/.ssh", 700)
        write_to_file(AUTHORIZED_KEYS_FILE, [keys].flatten.join("\n"))
        file_permissions(AUTHORIZED_KEYS_FILE, 600)
      end

      def add_authorized_key(key)
        run("touch -- #{shell_path(AUTHORIZED_KEYS_FILE)}")
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
