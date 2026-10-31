# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"
require "open3"
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
    # Content never goes into the command line: it is uploaded through the channel's
    # stdin (see Herd::Transport), so no line of it can end a heredoc or run as a command.
    #
    # For a wildcard use {#glob} and act on each path. In +run+/+sudo+ the shell is
    # yours; put a path into it with {#shell_path}:
    #
    #   run("find #{shell_path("~/my logs")} -name '*.log' -mtime +7")
    module Files
      class FileNotFound < StandardError; end
      class PermissionDeniedError < StandardError; end
      # install_file refuses to write through a symlink: the link could point anywhere.
      class SymlinkError < Herd::CommandError; end

      # What {#file_info} reports: type as stat names it ("regular file", "symbolic link", ...),
      # numeric and named owner, and the permission bits as octal digits ("644").
      FileInfo = Data.define(:type, :uid, :gid, :user, :group, :mode) do
        def symlink? = type == "symbolic link"
      end

      # Options of Host the ssh started by rsync can be given on its command line.
      RSYNC_SSH_IGNORED = %i[user password timeout logger verbose non_interactive keepalive keepalive_interval
                             keepalive_maxcount forward_agent number_of_password_prompts send_env set_env].freeze

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

      # Type, owner and mode of path itself (a symlink is not followed), or nil if nothing is there.
      # sudo: true stats as root, for paths inside directories the SSH user can't enter.
      def file_info(path, sudo: false)
        script = %(if [ -e "$1" ] || [ -L "$1" ]; then stat -c '%F|%u|%g|%U|%G|%a' -- "$1"; fi)
        line   = sh_script(script, shell_path(path), sudo: sudo).lines.map(&:strip).reject(&:empty?).last
        return unless line

        type, uid, gid, user, group, mode = line.split("|")
        FileInfo.new(type: type, uid: uid, gid: gid, user: user, group: group, mode: mode)
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
      # content is matched as a substring anywhere in the file, comments included.
      def file_contains?(path, content)
        return nil unless file_exists?(path)

        read_file!(path, sudo: true).include?(content)
      end

      # Puts content (with "\n" added if missing) before the file's current content,
      # creating the file if it doesn't exist. The file is rewritten through install_file,
      # keeping its owner and mode.
      def prepend_to_file(path, content, sudo: false, sensitive: false)
        content = "#{content}\n" unless content.end_with?("\n")
        current = file_exists?(path) ? read_bytes(path, sudo: sudo, sensitive: sensitive) : "".b

        install_file(path, content.b + current, sudo: sudo, sensitive: sensitive)
      end

      # Appends line unless the file already has a line exactly equal to it; creates the file
      # if it doesn't exist. Returns true if the line was added.
      #
      # The append doesn't rewrite the file, so lines written meanwhile by others are kept.
      # Two concurrent calls can both miss the line and both append it.
      def ensure_line_in_file(path, line, sudo: false, sensitive: false)
        return install_file(path, "#{line}\n", sudo: sudo, sensitive: sensitive) unless file_exists?(path)

        current = read_bytes(path, sudo: sudo, sensitive: sensitive)
        return false if current.dup.force_encoding(Encoding::UTF_8).lines(chomp: true).include?(line)

        separator = current.empty? || current.end_with?("\n") ? "" : "\n"
        append_to_file(path, "#{separator}#{line}\n", sudo: sudo, sensitive: sensitive)
        true
      end

      # Replaces the first match of pattern on each line, like sed 's/…/…/', but with Ruby
      # Regexp semantics. replacement is inserted literally (\1 is not a group reference);
      # for groups pass a block, which gets the MatchData:
      #
      #   replace_line_in_file(path, /^port (\d+)/) { |m| "port #{m[1].to_i + 1}" }
      #
      # Returns true if the file changed.
      def replace_line_in_file(path, pattern, replacement = nil, sudo: false, sensitive: false, &block)
        pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
        current = read_bytes(path, sudo: sudo, sensitive: sensitive).force_encoding(Encoding::UTF_8)
        updated = current.lines.map do |line|
          line.sub(pattern) { block ? yield(Regexp.last_match) : replacement }
        end.join
        return false if updated == current

        install_file(path, updated, sudo: sudo, sensitive: sensitive)
      end

      def dir(path, user = nil, group = nil)
        mkdir_p(path, user, group)
        source = "#{File.expand_path(File.join(FILES, path))}/"
        rsync(source, path, %w[-rptqz --checksum --force])

        dir_user_and_group(path, user, group) if user && group
      end

      # Installs a local file. mode defaults to the local file's permission bits, as rsync -p did.
      def upload_file(local_path, remote_path, user, group, mode: nil, sensitive: false)
        mode ||= format("%o", File.stat(local_path).mode & 0o7777)
        install_file(remote_path, File.binread(local_path), owner: user, group: group, mode: mode, sudo: true,
                                                            sensitive: sensitive)
      end

      def mkdir_p(path, user, group, sudo: false, mode: nil)
        cmd = "mkdir -p -- #{shell_path(path)}"
        sudo ? sudo(cmd) : run(cmd)

        file_user_and_group(path, user, group) if user && group
        file_permissions(path, mode) if mode
      end

      # Returns true if the content was rewritten. Owner/mode changes don't count.
      def file(path, user, group, content: File.read(File.join(FILES, path)), mode: nil, sensitive: false)
        install_file(path, content, owner: user, group: group, mode: mode, sudo: true, sensitive: sensitive)
      end

      # Returns true if the file was missing or its content differed and got rewritten.
      def expect_file_content_equals(path, required_content, sensitive: false)
        install_file(path, required_content, sudo: true, sensitive: sensitive)
      end

      # Makes path hold exactly content, owned and moded as given, and replaces it atomically:
      # readers see either the old file or the new one, never a partial write.
      #
      # - A symlink at path raises SymlinkError before anything is read; tee used to write
      #   through it into whatever it pointed at.
      # - Unchanged content isn't rewritten; a differing owner or mode is fixed in place.
      # - The new content goes into an exclusively created ".NAME.herd-XXXXXX" next to path,
      #   gets its owner and mode, passes validate, and only then is renamed over path.
      # - owner/group/mode default to those of the existing file. A new file belongs to the
      #   writing user (root with sudo: true) with mode 644, or 600 when sensitive: true.
      #
      # validate is a command with %{staged} in place of the file to check, e.g.
      # "visudo -cf %{staged}"; its failure leaves path untouched. sensitive: true keeps the
      # content and the validator's output out of the log.
      #
      # If the process is killed midway, path is still old or new, but the staged file may stay.
      # A path that is a mount point (/etc/hosts, /etc/resolv.conf in a container) can't be
      # renamed over; it is rewritten in place instead, which a reader may catch half-written.
      #
      # @return [Boolean] true if the content was written; an owner or mode fix alone is false
      def install_file(path, content, owner: nil, group: nil, mode: nil, sudo: false, validate: nil,
                       sensitive: false)
        info = file_info(path, sudo: sudo)
        raise SymlinkError, "install_file: #{path} is a symlink, refusing to write through it" if info&.symlink?

        mode = install_mode(info, mode, sensitive)
        if info && read_bytes(path, sudo: sudo, sensitive: sensitive) == content.b
          fix_metadata(path, info, owner, group, mode, sudo: sudo)
          return false
        end

        chown = install_owner(owner || info&.uid, group || info&.gid)
        with_upload(content, sensitive: sensitive) do |file|
          script = install_script(validate)
          sh_script(script, shell_path(path), file.shell_path, shell_args(chown.to_s, mode),
                    sudo: sudo, sensitive: sensitive)
        end
        true
      end

      def read_file!(path, sudo: false, sensitive: false)
        if file_readable?(path)
          read_file(path, sensitive: sensitive)
        elsif sudo
          read_file(path, sudo: true, sensitive: sensitive)
        else
          raise PermissionDeniedError, "'#{path}' is not readable"
        end
      end

      # The file's content as UTF-8 without its final line break ("\r\n", "\n" or "\r"),
      # as String#chomp removes it. Use read_bytes for the exact bytes.
      def read_file(path, sudo: false, sensitive: false)
        read_bytes(path, sudo: sudo, sensitive: sensitive).force_encoding(Encoding::UTF_8).chomp
      end

      # Writes without sudo when the SSH user can replace the file, with sudo when it can't and
      # sudo: true, otherwise raises PermissionDeniedError.
      def write_to_file!(path, content, sudo: false, sensitive: false)
        if file_replaceable?(path)
          write_to_file(path, content, sensitive: sensitive)
        elsif sudo
          write_to_file(path, content, sudo: true, sensitive: sensitive)
        else
          raise PermissionDeniedError, "'#{path}' can't be replaced by #{host&.user || "the SSH user"}"
        end
      end

      # Whether the SSH user can replace path the way install_file does: write a new file next
      # to it and rename it over. That takes write access to the directory, not just the file.
      def file_replaceable?(path)
        script = 'd=$(dirname -- "$1") && [ -w "$d" ] && [ -x "$d" ] && { [ ! -e "$1" ] || [ -w "$1" ]; }'
        command_success?("sh -c #{script.shellescape} _ #{shell_path(path)}", pty: false)
      end

      def mktemp
        run("mktemp").strip
      end

      # Replaces the file's content, adding a final "\n" if missing. See install_file.
      def write_to_file(path, content, sudo: false, sensitive: false)
        content = "#{content}\n" unless content.end_with?("\n")
        install_file(path, content, sudo: sudo, sensitive: sensitive)
      end

      # Appends content, adding a final "\n" if missing. The file is opened for append
      # (tee -a), not rewritten: a write cut short leaves a partial tail.
      def append_to_file(path, content, sudo: false, sensitive: false)
        content = "#{content}\n" unless content.end_with?("\n")
        with_upload(content, sensitive: sensitive) do |file|
          # The redirect is opened by the SSH user's shell (who owns the upload), tee by root with sudo.
          cmd = "tee -a -- #{shell_path(path)} < #{file.shell_path} > /dev/null"
          sudo ? sudo(cmd) : run(cmd)
        end
      end

      def dir_user_and_group(path, user, group)
        sudo("chown -R -- #{shell_args("#{user}:#{group}")} #{shell_path(path)}")
      end

      def file_user_and_group(path, user, group)
        sudo("chown -- #{shell_args("#{user}:#{group}")} #{shell_path(path)}")
      end

      def file_permissions(path, mode)
        sudo("chmod -- #{shell_args(mode)} #{shell_path(path)}")
      end

      # Copies local source to remote_path with rsync. A relative remote_path is taken
      # relative to +within+, as other file commands do.
      def rsync(source, remote_path, params)
        remote_path = File.join(@working_dir, remote_path) if @working_dir && !remote_path.start_with?("/", "~")
        destination = "#{host.host}:#{remote_path}"
        destination = "#{host.user}@#{destination}" if host.user

        # argv, not a shell string: source and destination reach rsync as they are.
        output, status = Open3.capture2e("rsync", *Array(params), "-e", rsync_communication_program,
                                         "--", source, destination)
        raise Herd::CommandError, output unless status.success?
      end

      # The ssh command rsync connects with. Options passed explicitly to Host are translated;
      # what ~/.ssh/config sets, ssh reads itself. An explicit option that ssh can't be given
      # raises UnsupportedSSHOption rather than having rsync connect differently from the session.
      # BatchMode=yes makes ssh fail instead of waiting for a password prompt nobody answers.
      def rsync_communication_program
        args = %w[ssh -o BatchMode=yes]
        host.explicit_ssh_options.each do |key, value|
          next if RSYNC_SSH_IGNORED.include?(key)

          args.concat(rsync_ssh_option(key, value))
        end
        args.map { |arg| rsync_quote(arg) }.join(" ")
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

      # Runs script with sh -c, args (already shell words) as $1, $2, ...; as root with sudo: true.
      def sh_script(script, *args, sudo: false, sensitive: false)
        command = "sh -c #{script.shellescape} _ #{args.join(" ")}"
        sudo ? sudo(command, sensitive: sensitive) : run(command, sensitive: sensitive)
      end

      # $1 target, $2 upload, $3 "owner:group" or "", $4 mode. The trap removes the staged
      # file when anything fails; mv clears it by renaming the file away.
      def install_script(validate)
        check = validate ? format(validate, staged: '"$staged"') : ":"
        <<~SH
          set -eu
          staged=$(mktemp "$(dirname "$1")/.$(basename "$1").herd-XXXXXX")
          trap 'rm -f -- "$staged" "$staged.err"' EXIT
          cat -- "$2" > "$staged"
          if [ -n "$3" ]; then chown -- "$3" "$staged"; fi
          chmod -- "$4" "$staged"
          #{check}
          # A mount point (/etc/hosts in a container) can't be renamed over: mv fails with
          # EBUSY, and only then the content is written in place, without atomicity.
          if ! LC_ALL=C mv -f -- "$staged" "$1" 2>"$staged.err"; then
            if grep -q 'Device or resource busy' "$staged.err"; then
              cat -- "$staged" > "$1"
              if [ -n "$3" ]; then chown -- "$3" "$1"; fi
              chmod -- "$4" "$1"
            else
              cat -- "$staged.err" >&2
              exit 1
            fi
          fi
        SH
      end

      # "owner:group", "owner", ":group" or "" for chown. A missing argument falls back to the
      # existing file's uid or gid independently, so giving only one keeps the other.
      def install_owner(owner, group)
        return "#{owner}:#{group}" if owner && group
        return owner.to_s if owner
        return ":#{group}" if group

        ""
      end

      def install_mode(info, mode, sensitive)
        return mode.to_s.sub(/\A0+(?=\d)/, "") if mode
        return info.mode if info

        sensitive ? "600" : "644"
      end

      def fix_metadata(path, info, owner, group, mode, sudo:)
        owner_ok = owner.nil? || [info.user, info.uid].include?(owner.to_s)
        group_ok = group.nil? || [info.group, info.gid].include?(group.to_s)
        unless owner_ok && group_ok
          cmd = "chown -- #{shell_args([owner, group].join(":").delete_suffix(":"))} #{shell_path(path)}"
          sudo ? sudo(cmd) : run(cmd)
        end
        return if info.mode == mode

        cmd = "chmod -- #{shell_args(mode)} #{shell_path(path)}"
        sudo ? sudo(cmd) : run(cmd)
      end

      def rsync_ssh_option(key, value)
        case key
        when :port then ["-p", value.to_s]
        when :keys then Array(value).flat_map { |k| ["-i", File.expand_path(k)] }
        when :keys_only then value ? %w[-o IdentitiesOnly=yes] : []
        when :config then value == false ? ["-F", File::NULL] : unsupported_ssh_option(key)
        when :proxy then rsync_proxy(value)
        when :user_known_hosts_file then ["-o", "UserKnownHostsFile=#{Array(value).join(" ")}"]
        when :global_known_hosts_file then ["-o", "GlobalKnownHostsFile=#{Array(value).join(" ")}"]
        when :host_key_alias then ["-o", "HostKeyAlias=#{value}"]
        when :verify_host_key then ["-o", "StrictHostKeyChecking=#{strict_host_key_checking(value)}"]
        else unsupported_ssh_option(key)
        end
      end

      def rsync_proxy(proxy)
        return ["-J", proxy.jump_proxies] if proxy.is_a?(Net::SSH::Proxy::Jump)

        unsupported_ssh_option(:proxy)
      end

      def strict_host_key_checking(value)
        case value
        when :never, false then "no"
        when :accept_new, :accept_new_or_local_tunnel then "accept-new"
        when :always, true, :very, :secure then "yes"
        else unsupported_ssh_option(:verify_host_key)
        end
      end

      def unsupported_ssh_option(key)
        raise Herd::UnsupportedSSHOption, "rsync: ssh option #{key.inspect} can't be passed to ssh"
      end

      # rsync splits -e on spaces and honours single and double quotes, but not backslashes.
      def rsync_quote(arg)
        return arg if arg.match?(%r{\A[\w.,/:@=+-]+\z})
        return "'#{arg}'" unless arg.include?("'")
        raise ArgumentError, "rsync: can't quote #{arg.inspect}" if arg.include?('"')

        %("#{arg}")
      end
    end
  end
end
