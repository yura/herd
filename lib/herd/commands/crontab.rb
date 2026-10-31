# frozen_string_literal: true

module Herd
  module Commands
    # The SSH user's crontab. Entries are installed from an uploaded file, so the shell
    # never expands them: "$HOME", backticks and % reach cron as written.
    module Crontab
      # Adds entry unless the crontab already has exactly that line. Returns true if added.
      def add_cron(entry)
        crontab_line!(entry)
        current = crontab_lines
        return false if current.include?(entry)

        crontab_install([*current, entry])
        true
      end

      # Replaces the whole crontab with entry (one line or several).
      def crontab(entry)
        crontab_install(entry.lines(chomp: true))
      end

      private

      def crontab_lines
        result = run_result("crontab -l", pty: false)
        return result.stdout.lines(chomp: true) if result.success?
        # A user who never had a crontab: exit 1 and "no crontab for <user>".
        return [] if result.exit_code == 1 && result.stderr.include?("no crontab for")

        raise Herd::CommandError, "crontab -l: #{result.stderr.strip}"
      end

      def crontab_install(lines)
        with_upload("#{lines.join("\n")}\n") { |file| run("crontab #{file.shell_path}", pty: false) }
      end

      def crontab_line!(entry)
        raise ArgumentError, "add_cron: entry must be one line" if entry.include?("\n")
      end
    end
  end
end
