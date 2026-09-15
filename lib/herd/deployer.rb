# frozen_string_literal: true

module Herd
  class Deployer
    TRACKING_DIR = "~/.herd_deploy"

    class Hook
      attr_reader :sha, :name, :pre_conditions_block, :actions_block, :checks_block,
                  :skip_on_hosts, :only_on_hosts, :skip_tags, :only_tags

      def initialize(sha, name)
        @sha           = sha
        @name          = name
        @skip_on_hosts = []
        @only_on_hosts = []
        @skip_tags     = []
        @only_tags     = []
      end

      def pre_conditions(&block) = @pre_conditions_block = block
      def actions(&block)        = @actions_block = block
      def checks(&block)         = @checks_block = block
      def skip_on(*hostnames)    = @skip_on_hosts = hostnames.flatten
      def only_on(*hostnames)    = @only_on_hosts = hostnames.flatten
      def skip_tagged(*tags)     = @skip_tags = tags.flatten
      def only_tagged(*tags)     = @only_tags = tags.flatten
    end

    # strict_branch: false keeps the historical behaviour of deploying whatever
    # branch the host is on, warning about the mismatch.
    def initialize(hosts_or_runner, app_path:, branch: "main", hooks_dir: nil, allow_untracked: false,
                   strict_branch: false)
      @runner          = hosts_or_runner.is_a?(Runner) ? hosts_or_runner : Runner.new(hosts_or_runner)
      @app_path        = app_path
      @branch          = branch
      @hooks           = {}
      @tracking        = "#{TRACKING_DIR}/#{File.basename(app_path)}/"
      @check_block     = nil
      @allow_untracked = allow_untracked
      @strict_branch   = strict_branch

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
      strict_branch    = @strict_branch

      @runner.exec do
        run("mkdir -p #{tracking}")

        current_branch = git_current_branch(app_path)
        if current_branch != branch
          info("warning: expected branch '#{branch}', got '#{current_branch}' — hooks will run against '#{branch}' commits")
        end

        if pull
          # The block runs after git_sync!'s refusals and before the merge, so a
          # deploy that is going to be refused never stops the app's services.
          sync_options = { ignore_untracked: allow_untracked, strict_branch: strict_branch }

          changed = git_sync!(app_path, branch, **sync_options) do
            instance_exec(&pre_pull_block) if pre_pull_block
          end

          info(changed.empty? ? "already up to date" : "updated #{changed.size} file(s)")

          within(app_path) { instance_exec(&post_pull_block) } if post_pull_block
        end

        within(app_path) do
          applied   = run("ls #{tracking} 2>/dev/null || true").scan(/[0-9a-f]{40}/)
          unapplied = hooks.keys - applied

          if unapplied.any?
            pending = git_commits_exist(app_path, *unapplied).sort_by { |sha| git_commit_time(app_path, sha) }

            if pending.empty?
              info("no pending hooks found in git log")
            else
              pending.each do |sha|
                hook = hooks[sha]

                hostname  = host.vars[:hostname]
                host_tags = Array(host.vars[:tags])
                next if hook.skip_on_hosts.include?(hostname)
                next if hook.only_on_hosts.any? && !hook.only_on_hosts.include?(hostname)
                next if hook.skip_tags.any? && (hook.skip_tags & host_tags).any?
                next if hook.only_tags.any? && (hook.only_tags & host_tags).none?
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
