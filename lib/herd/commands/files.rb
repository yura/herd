# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"
require "rsync"
require "shellwords"

module Herd
  module Commands
    FILES = "files"

    # Create, read, write, remove files, check permissions.
    #
    # A string means one of three things, depending on the method:
    #
    #   read_file("~/logs/*.log")  # one file, literally named "*.log"
    #   glob("~/logs/*.log")       # the files that match, as an array
    #   run("ls ~/logs/*.log")     # a shell command you write yourself
    #
    # File commands (read_file, write_to_file, file, ensure_symlink, mkdir_p,
    # file_permissions, ...) take one concrete path:
    # - spaces, quotes, $, *, ? are passed literally;
    # - "~" and "~/..." are the SSH user's home on the remote host, also with sudo: true;
    # - relative paths stay relative (to +within+, if any) — except a symlink target,
    #   which the kernel resolves from the link's own directory;
    # - paths go through {#shell_path} and get "--" where the command supports it.
    #
    # For a wildcard use {#glob} and act on each path. In +run+/+sudo+ the shell is
    # yours; put a path into it with {#shell_path}:
    #
    #   run("find #{shell_path("~/my logs")} -name '*.log' -mtime +7")
    module Files
      class FileNotFound < StandardError; end
      class PermissionDeniedError < StandardError; end

      # A remote path as one shell word: "~" and "~/..." mean the SSH user's home,
      # everything else (spaces, quotes, $) stays literal.
      #
      # @param path [String]
      # @return [String] ready to drop into a command
      def shell_path(path)
        path = path.to_s
        return '"$HOME"' if path == "~"
        return %("$HOME"/#{path.delete_prefix("~/").shellescape}) if path.start_with?("~/")

        path.shellescape
      end

      # Expands pattern on the remote host. Only *, ? and [...] are wildcards; $(), backticks
      # and ; are never run. "~/" is the SSH user's home, also with sudo: true.
      # Names come back hex-encoded, so spaces and newlines in them survive the PTY:
      # use the array as is, don't split command output instead.
      #
      #   glob("~/logs/*.log").each { |path| file_permissions(path, 640) }
      #
      # @param pattern [String]
      # @param sudo [Boolean] list as root, e.g. directories the user can't read
      # @return [Array<String>] matching paths, sorted; [] when nothing matches
      def glob(pattern, sudo: false)
        hex     = %(printf '%s' "$f" | od -An -tx1 | tr -d ' \\n'; echo)
        # nullglob only drops patterns with wildcards; a plain path comes through as-is, hence the -e/-L check.
        exists  = %([ -e "$f" ] || [ -L "$f" ] || continue)
        script  = "shopt -s nullglob; for f in #{glob_pattern(pattern)}; do #{exists}; #{hex}; done"
        command = %(bash -c #{script.shellescape} _ "$HOME")
        output  = sudo ? sudo(command) : run(command)
        output.split.map { |hex| [hex].pack("H*").force_encoding(Encoding::UTF_8) }.sort
      end

      # Escapes everything but the wildcards; inside [...] only plain class characters pass.
      def glob_pattern(pattern)
        home, rest = pattern.start_with?("~/") ? ['"$1"/', pattern.delete_prefix("~/")] : ["", pattern]
        in_class   = false

        home + rest.each_char.map do |char|
          if in_class
            in_class = false if char == "]"
            char.match?(/[\w.!^\-\]]/) ? char : "\\#{char}"
          elsif char == "["
            in_class = true
            char
          else
            "*?".include?(char) ? char : Shellwords.escape(char)
          end
        end.join
      end

      def file_exists?(path)
        path_test?("-e", path)
      end

      def file_readable?(path)
        path_test?("-r", path)
      end

      def file_writable?(path)
        path_test?("-w", path)
      end

      def symlink?(path)
        path_test?("-L", path)
      end

      # Points link at target, replacing a stale link or file. Returns true if it had to.
      # A relative target is stored as is and resolves from the link's directory, not +within+.
      # The check compares in the shell, so "~/x" matches the expanded path ln stored.
      # A real directory at link fails rm -f.
      def ensure_symlink(link, target, sudo: false)
        link   = shell_path(link)
        target = shell_path(target)
        return false if command_success?(%([ "$(readlink -- #{link})" = #{target} ]))

        ["rm -f -- #{link}", "ln -s -- #{target} #{link}"].each { |cmd| sudo ? sudo(cmd) : run(cmd) }
        true
      end

      # Returns nil if the file doesn't exist, false if it exists but doesn't contain content, true if it does.
      def file_contains?(path, content)
        return nil unless file_exists?(path)

        read_file!(path, sudo: true).include?(content)
      end

      # Always appends \n to content — otherwise the prepended line merges with the first line of the file.
      def prepend_to_file(path, content, sudo: false)
        run("touch -- #{shell_path(path)}") unless file_exists?(path)

        content = "#{content}\n" unless content.end_with?("\n")

        tmp = mktemp
        write_to_file(tmp, content)
        run("cat -- #{shell_path(path)} >> #{shell_path(tmp)}") unless file_contains?(path, content).nil?
        run("chmod --reference=#{shell_path(path)} -- #{shell_path(tmp)}")
        move = "mv -- #{shell_path(tmp)} #{shell_path(path)}"
        sudo ? sudo(move) : run(move)

        # FIXME: need to delete tmp file?
      end

      def ensure_line_in_file(path, line, sudo: false)
        run("touch -- #{shell_path(path)}") unless file_exists?(path)

        return if file_contains?(path, line)

        append_to_file(path, "#{line}\n", sudo: sudo)
      end

      def replace_line_in_file(path, pattern, replacement, sudo: false)
        escaped = replacement.gsub("/", "\\/")
        cmd = "sed -i -e 's/#{pattern.source}/#{escaped}/' -- #{shell_path(path)}"
        sudo ? sudo(cmd) : run(cmd)
      end

      def dir(path, user = nil, group = nil)
        mkdir_p(path, user, group)
        source = "#{File.expand_path(File.join(FILES, path))}/"
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
        cmd = "mkdir -p -- #{shell_path(path)}"
        sudo ? sudo(cmd) : run(cmd)

        file_user_and_group(path, user, group) if user && group
        file_permissions(path, mode) if mode
      end

      # Returns true if the content was rewritten. Owner/mode changes don't count.
      def file(path, user, group, content: File.read(File.join(FILES, path)), mode: nil)
        changed = expect_file_content_equals(path, content)

        file_user_and_group(path, user, group)
        file_permissions(path, mode) if mode
        changed
      end

      # Returns true if the file was missing or its content differed and got rewritten.
      def expect_file_content_equals(path, required_content)
        if file_exists?(path)
          actual_content = read_file!(path, sudo: true)
          return false if actual_content.lines(chomp: true) == required_content.lines(chomp: true)
        end

        write_to_file!(path, required_content, sudo: true)
        true
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
        cmd    = "cat -- #{shell_path(path)}"
        result = (sudo ? sudo(cmd) : run(cmd))&.chomp
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

      def mktemp
        run("mktemp").strip
      end

      def write_to_file(path, content, sudo: false)
        tee_heredoc("tee -- #{shell_path(path)} > /dev/null", content, sudo: sudo)
      end

      def append_to_file(path, content, sudo: false)
        tee_heredoc("tee -a -- #{shell_path(path)}", content, sudo: sudo)
      end

      # Quoted delimiter: content goes in literally. HERD_EOF, so a line reading "EOF" can't end it early.
      def tee_heredoc(tee, content, sudo: false)
        content = "#{content}\n" unless content.end_with?("\n")
        cmd = %(#{tee} << "HERD_EOF"\n#{content}HERD_EOF)
        sudo ? sudo(cmd) : run(cmd)
      end

      def dir_user_and_group(path, user, group)
        sudo("chown -R -- #{user}:#{group} #{shell_path(path)}")
      end

      def file_user_and_group(path, user, group)
        sudo("chown -- #{user}:#{group} #{shell_path(path)}")
      end

      def file_permissions(path, mode)
        sudo("chmod -- #{mode} #{shell_path(path)}")
      end

      def rsync(source, remote_path, params)
        destination = "#{host.host}:#{remote_path}"

        destination = "#{host.user}@#{destination}" if host.user

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

      private

      def path_test?(flag, path)
        command_success?("test #{flag} #{shell_path(path)}")
      end
    end
  end
end
