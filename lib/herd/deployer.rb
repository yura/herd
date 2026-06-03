# frozen_string_literal: true

module Herd
  class Deployer
    TRACKING_FILE = "~/.herd_deployed_commits"

    def initialize(runner, app_path:, hooks_dir: nil)
      @runner   = runner
      @app_path = app_path
      @hooks    = {}

      if hooks_dir
        Dir[File.join(hooks_dir, "**/*.rb")].sort.each do |file|
          instance_eval(File.read(file), file)
        end
      end
    end

    def on_commit(sha, &block)
      @hooks[sha] = block
    end

    def deploy(&after)
      hooks    = @hooks
      app_path = @app_path
      tracking = TRACKING_FILE

      @runner.exec do
        run("git -C #{app_path} pull")

        within(app_path) do
          applied = file_exists?(tracking) ? read_file(tracking).split(/\r?\n/).map(&:strip) : []
          unapplied = hooks.keys - applied

          if unapplied.any?
            all_commits = run("git log --format=%H")
                            .split(/\r?\n/).map(&:strip).reject(&:empty?)

            pending = all_commits.reverse.select { |sha| unapplied.include?(sha) }

            if pending.empty?
              info("no pending hooks found in git log")
            else
              pending.each do |sha|
                info("running hook for #{sha[0..7]}")
                instance_exec(&hooks[sha])
                append_to_file(tracking, sha)
                info("hook applied: #{sha[0..7]}")
              end
            end
          end

          instance_exec(&after) if after
        end
      end
    end
  end
end
