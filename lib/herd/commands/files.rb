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
        run("test -a #{path}; echo $?").chomp == "0"
      end

      def file_readable?(path)
        run("test -r #{path}; echo $?").chomp == "0"
      end

      def file_writable?(path)
        run("test -w #{path}; echo $?").chomp == "0"
      end

      def dir(path, user, group)
        mkdir_p(path, user, group)
        source = "#{File.expand_path(File.join(FILES, path))}/"
        destination = "#{host.user}@#{host.host}:#{path}"
        # --delete
        params = "-rptqz --checksum --force -e \"ssh -p #{host.port}\""

        Rsync.run(source, destination, params) do |result|
          # FIXME: raise some exception
          puts result.error unless result.success?
        end

        dir_user_and_group(path, user, group)
      end

      def mkdir_p(path, user, group, sudo: false, mode: nil)
        if sudo
          run("sudo mkdir -p #{path}")
        else
          run("mkdir -p #{path}")
        end
        file_user_and_group(path, user, group)
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
        command = "tee"
        command = "sudo #{command}" if sudo
        run(%(#{command} #{path} << "EOF"
#{content}EOF))
      end

      def append_to_file(path, content, sudo: false)
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

      def diff(actual, required)
        actual   = actual.lines(chomp: true)
        required = required.lines(chomp: true)

        diffs = Diff::LCS.diff actual, required
        Diff::LCS::Hunk.new(actual, required, diffs[0], 3, 0).diff(:unified)
      end
    end
  end
end
