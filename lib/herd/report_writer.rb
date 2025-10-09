# frozen_string_literal: true

require "fileutils"

module Herd
  # Writes report exports (summary + JSON) to the filesystem.
  module ReportWriter
    module_function

    def write(report, summary_path: nil, json_path: nil)
      write_summary(report, summary_path) if summary_path
      write_json(report, json_path) if json_path
    end

    def write_summary(report, path)
      ensure_directory(path)
      File.write(path, report.summary)
    end

    def write_json(report, path)
      ensure_directory(path)
      File.write(path, report.to_json)
    end

    def ensure_directory(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
    end
  end
end
