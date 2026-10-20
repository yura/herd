# frozen_string_literal: true

require "monitor"
require "prism"
require "securerandom"

module Herd
  module Commands
    # Values in this host's inventory file, e.g. passwords generated on first setup.
    # The key must already be in its register_server call, as nil or a string literal.
    module ServerConfig
      # Hosts run in parallel threads and several servers may share one file.
      LOCK = Monitor.new

      # Returns the key's value, generating and saving one if it's still nil.
      # Reads the file first: another Host may have saved it meanwhile.
      def server_secret(key, length: 22)
        LOCK.synchronize do
          server_config_get(key) || server_config_set(key, SecureRandom.alphanumeric(length))
        end
      end

      # The key's current value, synced into host.vars: the literal in this server's call,
      # else the loaded one (from **common or an expression like ENV[...]).
      def server_config_get(key)
        LOCK.synchronize do
          path  = host.vars[:config_file] || raise(ArgumentError, "#{host.host}: not loaded from an inventory file")
          pair, overridden = server_config_pair(File.read(path), path, key)
          node  = pair&.value unless overridden
          value = case node
                  when Prism::StringNode then node.unescaped
                  when Prism::NilNode    then nil
                  else host.vars[key]
                  end
          host.vars[key] = value if host.vars.key?(key)
          value
        end
      end

      # Replaces key's value in the inventory file, and in host.vars if it's a var
      # (SSH settings like password aren't). Returns value.
      def server_config_set(key, value)
        LOCK.synchronize do
          path   = server_config_key!(key)
          source = File.read(path)
          File.write(path, server_config_replace(source, server_config_node(source, key), value))
        end
        host.vars[key] = value if host.vars.key?(key)
        info("#{key} saved to #{File.basename(host.vars[:config_file])}")
        value
      end

      # Raises unless this server's register_server call has the key — call before
      # changing anything remotely that the file must then record. Returns the path.
      def server_config_key!(key)
        path = host.vars[:config_file] || raise(ArgumentError, "#{host.host}: not loaded from an inventory file")
        server_config_node(File.read(path), key)
        path
      end

      private

      # Swaps only the value's bytes (Prism offsets are byte offsets), so spacing stays.
      def server_config_replace(source, node, value)
        literal = value.to_s.match?(/['\\]/) ? value.to_s.inspect : "'#{value}'"
        source.b.bytesplice(node.location.start_offset, node.location.length, literal).force_encoding(source.encoding)
      end

      # The writable value node of key in register_server "<hostname>", ...: nil or a one-line string.
      # A key that only comes via **common is shared, so it's not writable from here.
      def server_config_node(source, key)
        path = host.vars[:config_file]
        pair, overridden = server_config_pair(source, path, key)
        raise Herd::CommandError, "#{key} not found for #{host.vars[:hostname]} in #{path}" unless pair
        raise Herd::CommandError, "#{key} in #{path} is overridden by a later **splat, move it after" if overridden

        value = pair.value
        return value if value.is_a?(Prism::NilNode) || (value.is_a?(Prism::StringNode) && !value.heredoc?)

        raise Herd::CommandError, "#{key} in #{path} is not nil or a one-line string, refusing to rewrite it"
      end

      # [pair, overridden]: pair is nil when this server's call doesn't spell the key out;
      # overridden when a **splat follows it, since Ruby then lets the splat win.
      def server_config_pair(source, path, key)
        name = host.vars[:hostname]
        call = server_config_call(Prism.parse(source, filepath: path).value, name)
        raise Herd::CommandError, "register_server #{name.inspect} not found in #{path}" unless call

        elements = call.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements)
        index    = elements.index do |el|
          el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == key.to_s
        end
        return [nil, false] unless index

        [elements[index], elements[(index + 1)..].any?(Prism::AssocSplatNode)]
      end

      def server_config_call(node, name)
        return node if server_config_call?(node, name)

        node.compact_child_nodes.each do |child|
          found = server_config_call(child, name)
          return found if found
        end
        nil
      end

      def server_config_call?(node, name)
        return false unless node.is_a?(Prism::CallNode) && node.name == :register_server && node.receiver.nil?

        first = node.arguments&.arguments&.first
        first.is_a?(Prism::StringNode) && first.unescaped == name
      end
    end
  end
end
