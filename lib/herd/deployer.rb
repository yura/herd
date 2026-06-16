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
      def actions(&block)        = @actions_block = block
      def checks(&block)         = @checks_block = block
    end

    def initialize(hosts_or_runner, app_path:, branch: "main", hooks_dir: nil, allow_untracked: false)
      @runner          = hosts_or_runner.is_a?(Runner) ? hosts_or_runner : Runner.new(hosts_or_runner)
      @app_path        = app_path
      @branch          = branch
      @hooks           = {}
      @tracking        = "#{TRACKING_DIR}/#{File.basename(app_path)}/"
      @check_block     = nil
      @allow_untracked = allow_untracked

      return unless hooks_dir

      Dir[File.join(hooks_dir, "*.rb")].each do |file|
        sha = File.basename(file).split("_").first
        next unless sha.match?(/\A[0-9a-f]{40}\z/)

        hook = Hook.new(sha, File.basename(file, ".rb"))
        hook.instance_eval(File.read(file), file)
        @hooks[sha] = hook
      end
    end

    def check(&block)
      @check_block = block
    end

    def pre_pull(&block)
      @pre_pull_block = block
    end

    def post_pull(&block)
      @post_pull_block = block
    end

    def after(&block)
      @after_block = block
    end

    def deploy
      run_deploy(pull: true)
    end

    def check_hooks(dry_run: true, &after)
      run_deploy(pull: false, fix: !dry_run, &after)
    end

    private

    def run_deploy(pull:, fix: true, &inline_after)
      hooks            = @hooks
      app_path         = @app_path
      tracking         = @tracking
      branch           = @branch
      check_block      = @check_block
      pre_pull_block   = @pre_pull_block
      post_pull_block  = @post_pull_block
      after_block      = @after_block
      allow_untracked  = @allow_untracked

      @runner.exec do
        run("mkdir -p #{tracking}")

        within(app_path) do
          current_branch = run("git rev-parse --abbrev-ref HEAD").strip
          if current_branch != branch
            info("warning: expected branch '#{branch}', got '#{current_branch}' — hooks will run against '#{branch}' commits")
          end

          if pull
            porcelain_flags = allow_untracked ? "--untracked-files=no" : ""
            dirty = run("git status --porcelain #{porcelain_flags}").strip
            raise Herd::CommandError, "uncommitted changes on server, aborting deploy" unless dirty.empty?
          end
        end

        if pull
          instance_exec(&pre_pull_block) if pre_pull_block
          run("git -C #{app_path} pull")
          within(app_path) { instance_exec(&post_pull_block) } if post_pull_block
        end

        within(app_path) do
          applied   = run("ls #{tracking} 2>/dev/null || true").scan(/[0-9a-f]{40}/)
          unapplied = hooks.keys - applied

          if unapplied.any?
            check = run("printf '#{unapplied.join("\\n")}' | git cat-file --batch-check")
                    .split(/\r?\n/).map(&:strip).reject(&:empty?)

            existing = check.select { |l| l.include?(" commit ") }
                            .map    { |l| l.split.first }

            pending = existing.sort_by do |sha|
              run("git log -1 --format=%ct #{sha}").strip.to_i
            end

            if pending.empty?
              info("no pending hooks found in git log")
            else
              pending.each do |sha|
                hook = hooks[sha]

                next if hook.pre_conditions_block && !instance_exec(&hook.pre_conditions_block)

                if fix
                  info("running hook for #{sha[0..7]}")
                  instance_exec(&hook.actions_block) if hook.actions_block
                  instance_exec(&hook.checks_block) if hook.checks_block
                  run("touch #{tracking}#{hook.name}")
                  info("hook applied: #{sha[0..7]}")
                else
                  info("pending hook: #{hook.name}")
                end
              end
            end
          else
            info("all hooks applied")
          end

          instance_exec(&after_block) if after_block
          instance_exec(&inline_after) if inline_after
        end
      ensure
        begin
          instance_exec(&check_block) if check_block
        rescue StandardError => e
          info("check failed: #{e.message}")
        end
      end
    end
  end
end
