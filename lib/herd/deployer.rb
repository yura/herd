# frozen_string_literal: true

module Herd
  class Deployer
    TRACKING_DIR = "~/.herd_deploy"

    def initialize(runner, app_path:, branch: "main", hooks_dir: nil)
      @runner   = runner
      @app_path = app_path
      @branch   = branch
      @hooks    = {}
      @tracking = "#{TRACKING_DIR}/#{File.basename(app_path)}"

      if hooks_dir
        Dir[File.join(hooks_dir, "**/*.rb")].sort.each do |file|
          instance_eval(File.read(file), file)
        end
      end
    end

    def on_commit(sha, &block)
      @hooks[sha] = block
    end

    def deploy(pull: false, &after)
      hooks    = @hooks
      app_path = @app_path
      tracking = @tracking
      tracking_dir = TRACKING_DIR

      branch = @branch

      @runner.exec do
        run("mkdir -p #{tracking_dir}")

        within(app_path) do
          current_branch = run("git rev-parse --abbrev-ref HEAD").strip
          if current_branch != branch
            info("warning: expected branch '#{branch}', got '#{current_branch}' — hooks will run against '#{branch}' commits")
          end

          if pull
            dirty = run("git status --porcelain").strip
            raise Herd::CommandError, "uncommitted changes on server, aborting deploy" unless dirty.empty?
          end
        end

        run("git -C #{app_path} pull") if pull

        within(app_path) do
          applied = file_exists?(tracking) ? read_file(tracking).split(/\r?\n/).map(&:strip) : []
          unapplied = hooks.keys - applied

          if unapplied.any?
            check = run("printf '#{unapplied.join("\\n")}' | git cat-file --batch-check")
                      .split(/\r?\n/).map(&:strip).reject(&:empty?)

            existing = check.select { |l| l.include?(" commit ") }
                            .map    { |l| l.split.first }

            pending = existing.sort_by { |sha|
              run("git log -1 --format=%ct #{sha}").strip.to_i
            }

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
