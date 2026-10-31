# frozen_string_literal: true

require "digest"
require "net/ssh"
require "securerandom"

module Herd
  # Pulls an app on each host and runs one-off hooks tied to commits (migrations, data
  # fixes), each once per host. A deploy goes through these phases:
  #
  #   lock → sync refusals → pre_pull → merge → post_pull → hooks → after → check → unlock
  #
  # deploy returns a DeployResult per host, or raises DeployError carrying them all when
  # any host didn't finish. on_failure gets the phase and the error when something fails
  # after pre_pull started — that's the place to bring stopped services back.
  class Deployer
    TRACKING_DIR = "~/.herd_deploy"
    APP_ID = /\A[\w.-]+\z/
    # Errors meaning the SSH connection itself broke: nothing more can run on that host.
    CONNECTION_ERRORS = [Net::SSH::Disconnect, IOError, Errno::ECONNRESET, Errno::EPIPE].freeze

    class DeployLocked < Herd::CommandError; end
    class CheckFailed < Herd::CommandError; end
    # The tracking dir records another app's path: two apps share a directory name.
    class TrackingDirTaken < Herd::CommandError; end

    # One host's outcome. status: :ok, :refused (stopped before anything changed),
    # :failed, or :unknown (timeout or broken connection: a command may still be running,
    # so the lock is left in place). phase is where it stopped; hook the hook it was in.
    DeployResult = Data.define(:host, :status, :phase, :hook, :applied, :pending, :error) do
      def ok? = status == :ok
    end

    # Raised by deploy when a host's status isn't :ok; results has every host's.
    class DeployError < Herd::CommandError
      attr_reader :results

      def initialize(results)
        @results = results
        failed   = results.reject(&:ok?)
        super(failed.map { |r| "#{r.host.host}: #{r.status} in #{r.phase}: #{r.error&.message}" }.join("; "))
      end
    end

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
      # Fails the hook by raising or by returning false; nil and anything else pass.
      def checks(&block)         = @checks_block = block
      def skip_on(*hostnames)    = @skip_on_hosts = hostnames.flatten
      def only_on(*hostnames)    = @only_on_hosts = hostnames.flatten
      def skip_tagged(*tags)     = @skip_tags = tags.flatten
      def only_tagged(*tags)     = @only_tags = tags.flatten
    end

    # Where a host's deploy is; read by the rescue around Host#exec when the block
    # never got to report a result.
    State = Struct.new(:phase, :hook, :applied, :pre_pull_ran, :lock_acquired)

    # strict_branch: false keeps the historical behaviour of deploying whatever
    # branch the host is on, warning about the mismatch.
    #
    # app_id names the tracking directory ~/.herd_deploy/<app_id>/. By default it's the app
    # directory's name plus a hash of its absolute path, so two apps with the same directory
    # name keep separate markers. The directory also records the app's path: an explicit
    # app_id shared by two apps is refused (TrackingDirTaken).
    def initialize(hosts_or_runner, app_path:, branch: "main", hooks_dir: nil, allow_untracked: false,
                   strict_branch: false, app_id: nil)
      # "." and ".." would make the tracking dir ~/.herd_deploy itself or the home directory.
      if app_id && (!app_id.match?(APP_ID) || %w[. ..].include?(app_id))
        raise ArgumentError, "Deployer: invalid app_id #{app_id.inspect}"
      end

      @runner          = hosts_or_runner.is_a?(Runner) ? hosts_or_runner : Runner.new(hosts_or_runner)
      @app_path        = app_path
      @branch          = branch
      @app_id          = app_id
      @hooks           = {}
      @allow_untracked = allow_untracked
      @strict_branch   = strict_branch
      @states          = {}
      @states_lock     = Mutex.new

      return unless hooks_dir

      Dir[File.join(hooks_dir, "*.rb")].each do |file|
        sha = File.basename(file).split("_").first
        next unless sha.match?(/\A[0-9a-f]{40}\z/)

        hook = Hook.new(sha, File.basename(file, ".rb"))
        hook.instance_eval(File.read(file), file)
        @hooks[hook.name] = hook
      end
    end

    # Health check after the after block. Fails the deploy by raising or returning false.
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

    # Runs with (phase, error) on the host when the deploy fails after pre_pull started.
    # Without it, services pre_pull stopped stay stopped (a warning says so). Not called
    # when the connection broke — there is nothing to run it on.
    def on_failure(&block)
      @on_failure_block = block
    end

    # The block runs after the after block, as in check_hooks.
    def deploy(&)
      run_deploy(pull: true, dry_run: false, &)
    end

    # dry_run: true (the default) only lists pending hooks: no lock, no tracking files,
    # no lifecycle blocks; pre_conditions run, so they must not change anything.
    # dry_run: false applies pending hooks without pulling, then after and check.
    def check_hooks(dry_run: true, &after)
      run_deploy(pull: false, dry_run: dry_run, &after)
    end

    private

    def run_deploy(pull:, dry_run:, &inline_after)
      # A state left from an earlier run would make a failed connection look like a deploy
      # interrupted midway, with that run's phase and hooks.
      @states_lock.synchronize { @states = {} }
      deployer = self
      results  = @runner.exec_results do
        deployer.send(:deploy_host, self, pull: pull, dry_run: dry_run, inline_after: inline_after)
      end

      results = results.map { |host, value, error| error ? broken_result(host, error) : value }
      raise DeployError, results unless results.all?(&:ok?)

      results
    end

    # A Host#exec that raised: either it never connected, or the connection broke mid-deploy.
    def broken_result(host, error)
      state = @states_lock.synchronize { @states[host] }
      return DeployResult.new(host, :failed, :connect, nil, [], [], error) unless state

      host.info("deploy interrupted in #{state.phase}: #{error.message} — lock left in place")
      DeployResult.new(host, :unknown, state.phase, state.hook, state.applied, [], error)
    end

    def deploy_host(session, pull:, dry_run:, inline_after:)
      state = State.new(:resolve, nil, [], false, false)
      @states_lock.synchronize { @states[session.host] = state }
      token     = SecureRandom.hex(16)
      # Fail-safe: the lock stays unless the run ends with a known outcome. A broken
      # connection or an exception that isn't a StandardError (Interrupt) never clears it.
      keep_lock = true

      begin
        app      = session.run("cd #{session.shell_path(@app_path)} && pwd -P", pty: false).strip
        tracking = tracking_dir(app)
        return dry_run_result(session, app, tracking) if dry_run

        state.phase = :lock
        prepare_tracking(session, app, tracking)
        acquire_lock(session, tracking, token)
        state.lock_acquired = true

        state.phase = :sync
        sync(session, app, state) if pull
        run_hooks(session, app, tracking, state)

        state.phase = :after
        state.hook = nil
        session.within(app) do
          session.instance_exec(&@after_block) if @after_block
          session.instance_exec(&inline_after) if inline_after
        end

        state.phase = :check
        if @check_block && session.within(app) { session.instance_exec(&@check_block) } == false
          raise CheckFailed, "check returned false"
        end

        known_outcome!(session, "the deploy")
        state.phase = :done
        keep_lock   = false
        DeployResult.new(session.host, :ok, :done, nil, state.applied, [], nil)
      rescue *CONNECTION_ERRORS
        raise # the rescue around Host#exec reports it from state
      rescue StandardError => e
        result    = failure_result(session, app, state, e)
        keep_lock = result.status == :unknown
        result
      ensure
        release_lock(session, tracking, token) if state.lock_acquired && !keep_lock
      end
    end

    def sync(session, app, state)
      pre_pull = @pre_pull_block
      changed  = session.git_sync!(app, @branch, ignore_untracked: @allow_untracked, strict_branch: @strict_branch) do
        # git_sync!'s refusals are behind us: from here on a failure may leave services stopped.
        state.phase        = :pre_pull
        state.pre_pull_ran = !pre_pull.nil?
        session.instance_exec(&pre_pull) if pre_pull
        state.phase = :merge
      end
      session.info(changed.empty? ? "already up to date" : "updated #{changed.size} file(s)")

      state.phase = :post_pull
      session.within(app) { session.instance_exec(&@post_pull_block) } if @post_pull_block
    end

    def run_hooks(session, app, tracking, state)
      state.phase = :hook
      pending = pending_hooks(session, app, tracking)
      session.info("all hooks applied") if pending.empty?

      session.within(app) do
        pending.each do |hook|
          next unless hook_applies?(session, hook)

          state.hook = hook.name
          session.info("running hook #{hook.name}")
          session.instance_exec(&hook.actions_block) if hook.actions_block
          if hook.checks_block && session.instance_exec(&hook.checks_block) == false
            raise CheckFailed, "hook #{hook.name}: checks returned false"
          end

          known_outcome!(session, "hook #{hook.name}")
          session.run("touch -- #{session.shell_path("#{tracking}/#{hook.name}")}", pty: false)
          state.applied << hook.name
          session.info("hook applied: #{hook.name}")
        end
      end
    end

    # The status is decided after on_failure ran: a recovery that timed out leaves the
    # outcome unknown as much as the error it recovered from.
    def failure_result(session, app, state, error)
      run_on_failure(session, app, state, error) if state.pre_pull_ran

      status = if unknown_outcome?(error) || session.outcome_unknown? then :unknown
               elsif %i[lock sync resolve].include?(state.phase) then :refused
               else :failed
               end
      return DeployResult.new(session.host, :refused, state.phase, nil, state.applied, [], error) if status == :refused

      session.info("deploy #{status} in #{state.phase}#{" (hook #{state.hook})" if state.hook}: #{error.message}")
      DeployResult.new(session.host, status, state.phase, state.hook, state.applied, [], error)
    end

    def run_on_failure(session, app, state, error)
      unless @on_failure_block
        session.info("pre_pull ran and deploy failed in #{state.phase}; no on_failure registered — " \
                     "services may be stopped")
        return
      end

      session.within(app) { session.instance_exec(state.phase, error, &@on_failure_block) }
    rescue StandardError => e
      session.info("on_failure failed: #{e.message}")
      error.define_singleton_method(:recovery_error) { e }
    end

    # Called where success gets recorded (a hook's marker, the :ok result): a timeout or killed
    # shell that a hook or block rescued still leaves the outcome unknown, so it can't count.
    def known_outcome!(session, what)
      return unless session.outcome_unknown?

      raise Herd::CommandOutcomeUnknown, "#{what} went on after a command whose outcome is unknown " \
                                         "(timeout or killed shell); not recording it as done"
    end

    # A timeout or a channel closed without exit status (a killed shell) leaves the remote
    # command possibly running; the lock must stay. Session#outcome_unknown? also covers one
    # that was rescued along the way, in a hook or in on_failure.
    def unknown_outcome?(error) = error.is_a?(Herd::CommandOutcomeUnknown)

    def dry_run_result(session, app, tracking)
      # A dry run moves nothing: until a deploy takes over the old dir, its markers count.
      source  = (!@app_id && legacy_tracking(session, app, tracking)) || tracking
      exists  = session.command_success?("test -d #{session.shell_path(source)}", pty: false)
      tracking_owner(session, app, source) if exists
      pending = pending_hooks(session, app, source, markers: exists)
      pending = session.within(app) { pending.select { |hook| hook_applies?(session, hook) } }
      pending.each { |hook| session.info("pending hook: #{hook.name}") }
      session.info("all hooks applied") if pending.empty?
      DeployResult.new(session.host, :ok, :dry_run, nil, [], pending.map(&:name), nil)
    end

    # Hooks not applied yet whose commit is in the history of HEAD, parents first;
    # hooks of one commit in file name order.
    def pending_hooks(session, app, tracking, markers: true)
      applied = markers ? applied_hooks(session, tracking) : []
      return [] if (@hooks.keys - applied).empty?

      position = session.git_history(app).each_with_index.to_h
      @hooks.values
            .reject { |hook| applied.include?(hook.name) }
            .select { |hook| position.key?(hook.sha) }
            .sort_by { |hook| [position.fetch(hook.sha), hook.name] }
    end

    def applied_hooks(session, tracking)
      session.run("ls -1A -- #{session.shell_path(tracking)}", pty: false).split("\n").map(&:strip)
    end

    def hook_applies?(session, hook)
      hostname  = session.host.vars[:hostname]
      host_tags = Array(session.host.vars[:tags])
      return false if hook.skip_on_hosts.include?(hostname)
      return false if hook.only_on_hosts.any? && !hook.only_on_hosts.include?(hostname)
      return false if hook.skip_tags.any? && hook.skip_tags.intersect?(host_tags)
      return false if hook.only_tags.any? && !hook.only_tags.intersect?(host_tags)
      return false if hook.pre_conditions_block && !session.instance_exec(&hook.pre_conditions_block)

      true
    end

    def tracking_dir(app)
      "#{TRACKING_DIR}/#{@app_id || "#{File.basename(app)}-#{Digest::SHA256.hexdigest(app)[0, 12]}"}"
    end

    # Creates the tracking dir and records the app's path in it.
    def prepare_tracking(session, app, tracking)
      adopt_legacy_tracking(session, app, tracking) unless @app_id
      session.run("mkdir -p -- #{session.shell_path(tracking)}", pty: false)
      return if tracking_owner(session, app, tracking)

      session.run("printf '%s\\n' #{session.shell_args(app)} > #{session.shell_path("#{tracking}/.app_path")}",
                  pty: false)
    end

    # Compatibility with Herd before 2026-10, whose tracking dir was named after the app
    # directory only (~/.herd_deploy/<name>/). Remove once those deploys have moved.
    #
    # The old dir doesn't say which app it was for, so the first app deployed with this name
    # takes it over: it is renamed to this app's tracking dir, markers and all. mv -T is
    # atomic, so of two deploys running at once only one gets it. A dir that already records
    # another app's path is left alone.
    def adopt_legacy_tracking(session, app, tracking)
      legacy = legacy_tracking(session, app, tracking) or return
      result = session.run_result("mv -T -- #{session.shell_path(legacy)} #{session.shell_path(tracking)}", pty: false)
      if result.success?
        session.info("hook markers moved from #{legacy} to #{tracking}")
      elsif !session.command_success?("test -d #{session.shell_path(tracking)}", pty: false)
        raise Herd::CommandError, "could not move #{legacy} to #{tracking}: #{result.stderr.strip}"
      end
    end

    # The pre-2026-10 tracking dir this app may take over, or nil: there is none, this app
    # already has its own, or it records another app.
    def legacy_tracking(session, app, tracking)
      legacy = "#{TRACKING_DIR}/#{File.basename(app)}"
      return if session.command_success?("test -d #{session.shell_path(tracking)}", pty: false)
      return unless session.command_success?("test -d #{session.shell_path(legacy)}", pty: false)

      recorded = session.run_result("cat -- #{session.shell_path("#{legacy}/.app_path")}", pty: false)
      return legacy unless recorded.success?

      recorded.stdout.chomp == app ? legacy : nil
    end

    # The app path recorded in the tracking dir, or nil if there is none yet. Raises
    # TrackingDirTaken when another app recorded its path there.
    def tracking_owner(session, app, tracking)
      recorded = session.run_result("cat -- #{session.shell_path("#{tracking}/.app_path")}", pty: false)
      return unless recorded.success?

      owner = recorded.stdout.chomp
      return owner if owner == app

      raise TrackingDirTaken, "#{tracking} holds the hook markers of #{owner}, not #{app}: both apps are named " \
                              "#{File.basename(app).inspect}. Pass this one its own app_id:, e.g. " \
                              "app_id: #{"#{File.basename(File.dirname(app))}-#{File.basename(app)}".inspect}"
    end

    # mkdir is atomic: only one deploy creates .lock. The owner file carries this run's
    # token; only the run holding it removes the lock.
    def acquire_lock(session, tracking, token)
      lock = session.shell_path("#{tracking}/.lock")
      if session.command_success?("mkdir -- #{lock}", pty: false)
        owner = "#{token}\n#{Socket.gethostname} pid #{Process.pid} at #{Time.now.utc}\n"
        session.run("cat > #{lock}/owner", pty: false, stdin: owner)
        return
      end

      owner = session.run_result("cat -- #{lock}/owner", pty: false).stdout.lines.drop(1).join.strip
      raise DeployLocked, "#{tracking} is locked by another deploy (#{owner.empty? ? "owner unknown" : owner}). " \
                          "If it is no longer running: rm -rf -- #{tracking}/.lock"
    end

    def release_lock(session, tracking, token)
      script = 'if [ "$(head -n 1 -- "$1/owner" 2>/dev/null)" = "$2" ]; then rm -rf -- "$1"; fi'
      session.run("sh -c #{script.shellescape} _ #{session.shell_path("#{tracking}/.lock")} #{token}", pty: false)
    rescue StandardError => e
      session.info("could not release the deploy lock: #{e.message}")
    end
  end
end
