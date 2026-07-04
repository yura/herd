# frozen_string_literal: true

require "fileutils"
require "json"

module Herd
  # Methods for logging commands, outputs and errors.
  module Log
    def info(message)
      label = host.vars[:hostname] || host.host
      puts "[#{label}] #{message}"
    end

    def log_file_path
      dir = "log/#{vars[:host]}_#{vars[:port]}_#{vars[:user]}"
      FileUtils.mkdir_p(dir)
      "#{File.join(dir, Time.now.strftime("%Y%m%d_%H%M%S"))}.json"
    end

    def open_log
      @log = File.open(log_file_path, "w")

      log.puts "{"
      log.print({ vars: vars }.to_json)
      log.flush
    end

    def close_log
      log.puts "\n}"
      log.close
    end

    def log_connection_error(error)
      log.puts ","
      log.print({ error: error.message, error_trace: error.backtrace }.to_json)
      log.flush
    end

    def log_command_start(timestamp, command, caller_method = nil)
      log.puts(",")
      entry = { timestamp: time(timestamp), command: command }
      entry[:caller] = caller_method if caller_method
      log.print(entry.to_json)
      log.flush
    end

    def log_command_output(command, output, started_at, caller_method = nil)
      now = Time.now
      log.puts(",")
      entry = { timestamp: time(now), command: command, output: scrub(output), time: now - started_at }
      entry[:caller] = caller_method if caller_method
      log.print(entry.to_json)
      log.flush
    end

    def log_command_error(command, error, started_at, exit_code, caller_method = nil)
      now = Time.now
      log.puts(",")
      entry = { timestamp: time(now), command: command, error: scrub(error), exit_code: exit_code,
                time: now - started_at }
      entry[:caller] = caller_method if caller_method
      log.print(entry.to_json)
      log.flush
    end

    def time(timestamp = Time.now)
      timestamp.strftime("%Y-%m-%d %H:%M:%S.%L")
    end

    private

    # SSH output can arrive truncated mid-character (e.g. exit-status racing the
    # final data chunk), leaving invalid byte sequences that blow up JSON#generate.
    def scrub(str)
      return str unless str.is_a?(String)

      str.scrub
    end
  end
end
