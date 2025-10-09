# frozen_string_literal: true

require "herd"
require "json"

RSpec.describe Herd::RunReport do
  subject(:report) { described_class.new }

  describe "task lifecycle tracking" do
    let(:start_time) { Time.at(1.0) }
    let(:finish_time) { Time.at(4.5) }

    it "records successful execution with output and timing" do
      allow(Time).to receive(:now).and_return(start_time, finish_time)

      event = report.task_started(
        host: "alpha",
        task: "install_nginx",
        command: "apt-get install nginx"
      )

      report.task_succeeded(
        event: event,
        stdout: "nginx installed\n",
        stderr: ""
      )

      expect(report.events).to contain_exactly(
        include(
          host: "alpha",
          task: "install_nginx",
          command: "apt-get install nginx",
          status: :success,
          started_at: start_time,
          finished_at: finish_time,
          duration: finish_time - start_time,
          stdout: "nginx installed\n",
          stderr: "",
          exception: nil
        )
      )
    end

    it "records failures with exception metadata" do
      error = RuntimeError.new("package not found")
      error.set_backtrace(["/srv/setup.rb:12", "/srv/main.rb:3"])

      allow(Time).to receive(:now).and_return(start_time, finish_time)

      event = report.task_started(
        host: "beta",
        task: "clone_repo",
        command: "git clone git@example.com:app.git"
      )

      report.task_failed(
        event: event,
        exception: error,
        stdout: "",
        stderr: "fatal: repository not found\n"
      )

      entry = report.events.first

      expect(entry).to include(
        host: "beta",
        task: "clone_repo",
        command: "git clone git@example.com:app.git",
        status: :failed,
        started_at: start_time,
        finished_at: finish_time,
        duration: finish_time - start_time,
        stdout: "",
        stderr: "fatal: repository not found\n"
      )

      expect(entry[:exception]).to eq(
        class: "RuntimeError",
        message: "package not found",
        backtrace: ["/srv/setup.rb:12", "/srv/main.rb:3"]
      )
    end

    it "records skipped tasks with reasons" do
      allow(Time).to receive(:now).and_return(start_time, finish_time)

      event = report.task_started(
        host: "gamma",
        task: "configure",
        command: "configure"
      )

      report.task_skipped(event: event, reason: "dependency failed")

      entry = report.events.first

      expect(entry).to include(
        host: "gamma",
        task: "configure",
        status: :skipped,
        stdout: nil,
        stderr: nil,
        skip_reason: "dependency failed"
      )
    end
  end

  describe "aggregations" do
    let(:start_time) { Time.utc(2024, 1, 1, 12, 0, 0) }
    let(:mid_time) { start_time + 5 }
    let(:end_time) { start_time + 10 }
    let(:clock_values) { [start_time, mid_time, start_time + 7, end_time, end_time + 2, end_time + 4] }
    let(:report) { described_class.new(clock: -> { clock_values.shift }) }

    it "renders a console summary" do
      first = report.task_started(host: "alpha", task: "install", command: "install")
      report.task_succeeded(event: first, stdout: "ok", stderr: "")

      second = report.task_started(host: "beta", task: "clone", command: "clone")
      report.task_failed(event: second, exception: RuntimeError.new("boom"), stdout: "", stderr: "boom")

      third = report.task_started(host: "gamma", task: "configure", command: "configure")
      report.task_skipped(event: third, reason: "dependency failed")

      summary = report.summary

      expect(summary).to include("Tasks: 3 total")
      expect(summary).to include("success: 1")
      expect(summary).to include("failed: 1")
      expect(summary).to include("skipped: 1")
      expect(summary).to include("install@alpha")
      expect(summary).to include("clone@beta")
      expect(summary).to include("configure@gamma")
      expect(summary).to include("RuntimeError")
      expect(summary).to include("dependency failed")
    end

    it "serializes report as JSON" do
      event = report.task_started(host: "alpha", task: "install", command: "install")
      report.task_succeeded(event: event, stdout: "ok", stderr: "")

      data = JSON.parse(report.to_json)

      expect(data["totals"]).to include("total" => 1, "success" => 1)
      expect(data["duration"]).to eq((mid_time - start_time))

      serialized_event = data["events"].first
      expect(serialized_event).to include(
        "host" => "alpha",
        "task" => "install",
        "status" => "success",
        "stdout" => "ok",
        "stderr" => ""
      )
      expect(serialized_event["started_at"]).to eq(start_time.iso8601)
      expect(serialized_event["finished_at"]).to eq(mid_time.iso8601)
    end
  end
end
