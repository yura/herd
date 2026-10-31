# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Herd
  # Methods for logging commands, outputs and errors.
  #
  # One JSON object per line (JSON Lines): the first is {"vars": ...}, then one per
  # command start, result and connection error. Entries of a sensitive: true command
  # have "[redacted]" in place of the command, output and error.
  module Log
    REDACTED = "[redacted]"
    # Values shorter than this aren't scrubbed from log text: "1" or "yes" would blank out half the log.
    MIN_SCRUBBED_SECRET = 6

    def info(message)
      label = host.vars[:hostname] || host.host
      puts "[#{label}] #{message}"
    end

    # Milliseconds, pid and a random suffix: two runs never get the same name, and the
    # file is created with EXCL, so an existing log is never overwritten.
    def log_file_path
      dir = "log/#{vars[:host]}_#{vars[:port]}_#{vars[:user]}"
      FileUtils.mkdir_p(dir, mode: 0o700)
      name = "#{Time.now.strftime("%Y%m%d_%H%M%S.%L")}_#{Process.pid}_#{SecureRandom.hex(3)}.jsonl"
      File.join(dir, name)
    end

    def open_log
      @log = File.open(log_file_path, File::WRONLY | File::CREAT | File::EXCL, 0o600)
      log_entry(vars: redacted_vars)
    end

    def close_log
      log.close
    end

    def log_connection_error(error)
      log_entry(error: error.message, error_trace: error.backtrace)
    end

    def log_command_start(timestamp, command, caller_method = nil, sensitive: false, input: nil)
      entry = { timestamp: time(timestamp) }
      entry[:caller] = caller_method if caller_method
      entry[:command] = sensitive ? REDACTED : command
      entry[:input] = sensitive ? REDACTED : "#{input.bytesize} bytes" if input
      log_entry(entry)
    end

    def log_command_output(command, result, started_at, caller_method = nil, sensitive: false)
      log_entry(result_entry(command, result, started_at, caller_method, sensitive)
                  .merge(output: sensitive ? REDACTED : scrub(result.stdout))
                  .merge(stderr_field(result, sensitive)))
    end

    def log_command_error(command, result, started_at, caller_method = nil, sensitive: false)
      log_entry(result_entry(command, result, started_at, caller_method, sensitive)
                  .merge(error: sensitive ? REDACTED : scrub(result.stdout))
                  .merge(stderr_field(result, sensitive))
                  .merge(exit_code: result.exit_code))
    end

    def time(timestamp = Time.now)
      timestamp.strftime("%Y-%m-%d %H:%M:%S.%L")
    end

    # Secret values registered with Session#secret and the host's password; Host overrides it.
    def known_secrets
      host ? host.known_secrets : []
    end

    private

    def result_entry(command, result, started_at, caller_method, sensitive)
      now   = Time.now
      entry = { timestamp: time(now) }
      entry[:caller] = caller_method if caller_method
      entry.merge(command: sensitive ? REDACTED : command, exit_code: result.exit_code, time: now - started_at)
    end

    def stderr_field(result, sensitive)
      return {} if result.stderr.empty?

      { stderr: sensitive ? REDACTED : scrub(result.stderr) }
    end

    def log_entry(entry)
      log.puts(scrub_secrets(JSON.generate(entry)))
      log.flush
    end

    # host vars with the values of sensitive keys (Host#sensitive_key?) replaced.
    def redacted_vars
      vars.to_h { |key, value| [key, sensitive_key?(key) ? REDACTED : value] }
    end

    # The explicit sensitive: flag is what keeps secrets out; this is a second line
    # for a secret that got into a command or output unflagged.
    def scrub_secrets(line)
      known_secrets.select { |secret| secret.is_a?(String) && secret.length >= MIN_SCRUBBED_SECRET }
                   .reduce(line) { |text, secret| text.gsub(JSON.generate(secret)[1...-1], REDACTED) }
    end

    # SSH output arrives as bytes; invalid UTF-8 (a chunk cut mid-character, binary
    # output) would make JSON.generate raise, so it becomes U+FFFD.
    def scrub(str)
      return str unless str.is_a?(String)

      str.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
