# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"
require "rsync"

module Herd
  module Commands
    FILES = "files"

    # Create, read, write, remove files, check permssions.
    module Files
      class PermissionDeniedError < StandardError; end

      def file_exists?(path)
        run("test -e #{path} && echo yes || echo no").chomp == "yes"
      end

      def file_readable?(path)
        run("test -r #{path} && echo yes || echo no").chomp == "yes"
      end

      def file_writable?(path)
        run("test -w #{path} && echo yes || echo no").chomp == "yes"
      end

      def symlink?(path)
        run("test -L #{path} && echo yes || echo no").chomp == "yes"
      end

      # Returns nil if the file doesn't exist, false if it exists but doesn't contain content, true if it does.
      def file_contains?(path, content)
        return nil unless file_exists?(path) # rubocop:disable Style/ReturnNilInPredicateMethodDefinition

        read_file!(path, sudo: true)&.include?(content) || false
      end

      # Always appends \n to content — otherwise the prepended line merges with the first line of the file.
      def prepend_to_file(path, content, sudo: false)
        return if file_contains?(path, content)

        content = "#{content}\n" unless content.end_with?("\n")

        tmp = "/tmp/herd_prepend_#{Process.pid}"
        write_to_file(tmp, content)
        run("cat #{path} >> #{tmp}") unless file_contains?(path, content).nil?
        run("chmod --reference=#{path} #{tmp}") if file_exists?(path)
        run(sudo ? "sudo mv #{tmp} #{path}" : "mv #{tmp} #{path}")
      end

      def ensure_line_in_file(path, line, sudo: false)
        return if file_contains?(path, line)

        append_to_file(path, "#{line}\n", sudo: sudo)
      end

      def replace_line_in_file(path, pattern, replacement, sudo: false)
        escaped = replacement.gsub("/", "\\/")
        cmd = "sed -i 's/#{pattern.source}/#{escaped}/' #{path}"
        sudo ? sudo(cmd) : run(cmd)
      end

      def dir(path, user = nil, group = nil)
        mkdir_p(path, user, group)
        source      = "#{File.expand_path(File.join(FILES, path))}/"
        rsync(source, path, "-rptqz --checksum --force")

        dir_user_and_group(path, user, group) if user && group
      end

      def upload_file(local_path, remote_path, user, group, mode: nil)
        params = "-ptqz --checksum"

        rsync(local_path, remote_path, params)
        file_user_and_group(remote_path, user, group)
        file_permissions(remote_path, mode) if mode
      end

      def mkdir_p(path, user, group, sudo: false, mode: nil)
        if sudo
          sudo("mkdir -p #{path}")
        else
          run("mkdir -p #{path}")
        end

        file_user_and_group(path, user, group) if user && group
        file_permissions(path, mode) if mode
      end

      def file(path, user, group, content: File.read(File.join(FILES, path)), mode: nil)
        expect_file_content_equals(path, content)

        file_user_and_group(path, user, group)
        file_permissions(path, mode) if mode
      end

      def expect_file_content_equals(path, required_content)
        if file_exists?(path)
          actual_content = read_file!(path, sudo: true)
          unless actual_content.lines(chomp: true) == required_content.lines(chomp: true)
            # "File has been replaced with diff:\n\n#{diff(actual_content, required_content)}"
            write_to_file!(path, required_content, sudo: true)
          end
        else
          write_to_file!(path, required_content, sudo: true)
        end
      end

      def read_file!(path, sudo: false)
        if file_readable?(path)
          read_file(path)
        elsif sudo
          read_file(path, sudo: true)
        else
          raise PermissionDeniedError, "'#{path}' is not readable"
        end
      end

      def read_file(path, sudo: false)
        command = "cat #{path}"
        command = "sudo #{command}" if sudo

        result = run(command)&.chomp
        result = result.sub(/\A(\r\n|\r|\n)/, "") if sudo

        result
      end

      def write_to_file!(path, content, sudo: false)
        if file_writable?(path)
          write_to_file(path, content)
        elsif sudo
          write_to_file(path, content, sudo: true)
        else
          raise PermissionDeniedError, "'#{path}' is not writable"
        end
      end

      def write_to_file(path, content, sudo: false)
        content = "#{content}\n" unless content.end_with?("\n")
        command = "tee"
        command = "sudo #{command}" if sudo
        run(%(#{command} #{path} > /dev/null << "EOF"
#{content}EOF))
      end

      def append_to_file(path, content, sudo: false)
        content = "#{content}\n" unless content.end_with?("\n")
        command = "tee -a"
        command = "sudo #{command}" if sudo
        run(%(#{command} #{path} << "EOF"
#{content}EOF))
      end

      def dir_user_and_group(path, user, group)
        sudo("chown -R #{user}:#{group} #{path}")
      end

      def file_user_and_group(path, user, group)
        sudo("chown #{user}:#{group} #{path}")
      end

      def file_permissions(path, mode)
        sudo("chmod #{mode} #{path}")
      end

      def rsync(source, remote_path, params)
        destination = "#{host.host}:#{remote_path}"

        if host.user
          destination = "#{host.user}@#{destination}"
        end

        params = "#{params} -e \"#{rsync_communication_program}\""

        Rsync.run(source, destination, params) do |result|
          raise Herd::CommandError, result.error unless result.success?
        end
      end

      def rsync_communication_program
        if host.port
          "ssh -p #{host.port}"
        else
          "ssh"
        end
      end

      def diff(actual, required)
        actual   = actual.lines(chomp: true)
        required = required.lines(chomp: true)

        diffs = Diff::LCS.diff actual, required
        Diff::LCS::Hunk.new(actual, required, diffs[0], 3, 0).diff(:unified)
      end
    end
  end
end
