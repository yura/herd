# frozen_string_literal: true

require "shellwords"

module Herd
  # Moves data between Ruby and the remote host without putting it into a command line:
  # a heredoc ends early on a line equal to its delimiter, and argv is visible in /proc.
  module Transport
    # A temporary file on the remote host, owned by the SSH user, mode 0600.
    # sensitive is carried along so that every command reading the file is logged as sensitive too.
    Upload = Data.define(:path, :sensitive) do
      def shell_path = path.shellescape
    end

    B64_BEGIN = "HERD_B64>"
    B64_END   = "<HERD_B64"

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

    # Literal arguments as shell words. Unlike shell_path, "~" is not expanded.
    def shell_args(*args)
      args.flatten.map(&:to_s).shelljoin
    end

    # Writes bytes to a new remote temporary file through the stdin of a PTY-less channel.
    # Prefer {#with_upload}, which also removes the file.
    #
    # @return [Upload]
    def upload(bytes, sensitive: false)
      path = run(%(mktemp "${TMPDIR:-/tmp}/herd-upload.XXXXXX"), pty: false).strip
      file = Upload.new(path: path, sensitive: sensitive)
      run("cat > #{file.shell_path}", pty: false, stdin: bytes.b, sensitive: sensitive)

      size = run("wc -c < #{file.shell_path}", pty: false).strip.to_i
      if size != bytes.bytesize
        raise Herd::CommandError,
              "upload: #{path} has #{size} bytes, expected #{bytes.bytesize}"
      end

      uploaded = true
      file
    ensure
      # In ensure with a flag rather than in rescue: an Interrupt midway removes it too.
      remove_upload(file) if file && !uploaded
    end

    # Yields an {Upload} of bytes and removes it afterwards.
    #
    # With sensitive: true every command run inside the block is logged as sensitive:
    # whatever reads the file (psql, chpasswd, visudo) may quote it in its diagnostics.
    #
    # A failed removal is logged; when the block raised, it is also attached to that
    # error (cleanup_errors) and never replaces it.
    def with_upload(bytes, sensitive: false)
      file = upload(bytes, sensitive: sensitive)
      @sensitive_uploads = @sensitive_uploads.to_i + 1 if sensitive
      yield file
    rescue StandardError => e
      failure = e
      raise
    ensure
      # In ensure, not after the block: break, return and Interrupt leave through here too.
      if file
        @sensitive_uploads -= 1 if sensitive
        cleanup = remove_upload(file)
        Herd.attach_cleanup_error(failure, cleanup) if failure && cleanup
      end
    end

    # True inside the block of a sensitive with_upload.
    def inside_sensitive_upload? = @sensitive_uploads.to_i.positive?

    # The file's exact bytes (BINARY encoding). Without sudo they come over a PTY-less
    # channel; with sudo the password prompt needs a PTY, which may rewrite "\n" as "\r\n",
    # so the content travels base64-encoded between markers.
    #
    # @raise [Herd::CommandError] if the file can't be read
    def read_bytes(path, sudo: false, sensitive: false)
      return run("cat -- #{shell_path(path)}", pty: false, sensitive: sensitive).b unless sudo

      # && rather than ;: the command's exit status must be cat's, not the last printf's.
      output = run("printf '#{B64_BEGIN}' && #{sudo_prefix} cat -- #{shell_path(path)} | base64 | tr -d '\\n' " \
                   "&& printf '#{B64_END}'", sensitive: sensitive, sudo_prompt: true)
      decode_marked_base64(output, path)
    end

    private

    # Returns the error when the file couldn't be removed, after logging it; nil otherwise.
    def remove_upload(file)
      result = run_result("rm -f -- #{file.shell_path}", pty: false)
      return if result.success?

      Herd::CommandError.new("could not remove #{file.path}: #{result.stderr.strip}").tap { |e| info(e.message) }
    rescue StandardError => e
      info("could not remove #{file.path}: #{e.message}")
      e
    end

    def decode_marked_base64(output, path)
      from = output.index(B64_BEGIN)
      to   = from && output.index(B64_END, from)
      raise Herd::CommandError, "read_bytes: no content markers in the output for #{path}" unless to

      # m0 is strict base64: anything but the alphabet and correct padding raises ArgumentError.
      output[(from + B64_BEGIN.length)...to].delete("\r\n").unpack1("m0")
    rescue ArgumentError
      raise Herd::CommandError, "read_bytes: corrupted base64 for #{path}"
    end
  end
end
