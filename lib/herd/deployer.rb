# frozen_string_literal: true

module Herd
  class Deployer
    TRACKING_DIR = "~/.herd_deploy"

    class Hook
      attr_reader :sha, :name, :pre_conditions_block, :actions_block, :checks_block

      def initialize(sha, name)
        @sha  = sha
        @name = name
      end

      def pre_conditions(&block) = @pre_conditions_block = block
      def actions(&block)        = @actions_block        = block
      def checks(&block)         = @checks_block         = block
    end

    def initialize(runner, app_path:, branch: "main", hooks_dir: nil)
      @runner   = runner
      @app_path = app_path
      @branch   = branch
      @hooks    = {}
      @tracking = "#{TRACKING_DIR}/#{File.basename(app_path)}/"

      if hooks_dir
        Dir[File.join(hooks_dir, "*.rb")].sort.each do |file|
          sha = File.basename(file).split("_").first
          next unless sha.match?(/\A[0-9a-f]{40}\z/)

          hook = Hook.new(sha, File.basename(file, ".rb"))
          hook.instance_eval(File.read(file), file)
          @hooks[sha] = hook
        end
      end
    end

    def deploy(pull: false, &after)
      hooks    = @hooks
      app_path = @app_path
      tracking = @tracking
      branch   = @branch

      @runner.exec do
        run("mkdir -p #{tracking}")

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
          applied = run("ls #{tracking} 2>/dev/null || true").scan(/[0-9a-f]{40}/)
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
                hook = hooks[sha]

                if hook.pre_conditions_block
                  next unless instance_exec(&hook.pre_conditions_block)
                end

                info("running hook for #{sha[0..7]}")
                instance_exec(&hook.actions_block) if hook.actions_block
                instance_exec(&hook.checks_block) if hook.checks_block
                run("touch #{tracking}#{hook.name}")
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
