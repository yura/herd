# frozen_string_literal: true

require "fileutils"

module Herd
  # Writes report exports (summary + JSON) to the filesystem.
  module ReportWriter
    module_function

    # Writes the summary and/or JSON representation to disk.
    #
    # @param report [Herd::RunReport]
    # @param summary_path [String, nil] target path for human-readable summary.
    # @param json_path [String, nil] target path for JSON export.
    # @return [void]
    def write(report, summary_path: nil, json_path: nil)
      write_summary(report, summary_path) if summary_path
      write_json(report, json_path) if json_path
    end

    # Writes the formatted summary to the supplied path.
    #
    # @param report [Herd::RunReport]
    # @param path [String]
    # @return [void]
    def write_summary(report, path)
      ensure_directory(path)
      File.write(path, report.summary)
    end

    # Writes the JSON export to the supplied path.
    #
    # @param report [Herd::RunReport]
    # @param path [String]
    # @return [void]
    def write_json(report, path)
      ensure_directory(path)
      File.write(path, report.to_json)
    end

    # Ensures the parent directory for the target path exists.
    #
    # @param path [String]
    # @return [void]
    def ensure_directory(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
    end
  end
end
