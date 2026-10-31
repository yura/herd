# frozen_string_literal: true

require_relative "system_helper"
require_relative "git_helper"

# Deployer against real repositories in the container. Hook files are Ruby DSL read on
# the machine running the specs, so they go to the project's gitignored tmp/.
RSpec.describe Herd::Deployer, :system do
  let(:hooks_dir) { Dir.mktmpdir("herd-hooks-", File.expand_path("../../tmp", __dir__).tap { FileUtils.mkdir_p(it) }) }

  # Tracking dirs live in the SSH user's home, shared by all examples.
  before { on_system_host { run("rm -rf ~/.herd_deploy", pty: false) } }
  after { FileUtils.rm_rf(hooks_dir) }

  # The tracking dir that recorded dir/app as its app.
  def tracking_of(s, dir)
    app = s.run("cd #{s.shell_path("#{dir}/app")} && pwd -P", pty: false).strip
    s.run("grep -l -x -F -- #{s.shell_args(app)} ~/.herd_deploy/*/.app_path",
          pty: false).strip.delete_suffix("/.app_path")
  end

  # A hook that appends its name to dir/ran; checks returns what's given.
  def hook(sha, name, dir, checks: true)
    File.write(File.join(hooks_dir, "#{sha}_#{name}.rb"), <<~RUBY)
      actions { run("echo #{name} >> #{dir}/ran") }
      checks { #{checks.inspect} }
    RUBY
  end

  def short(names) = names.map { it.sub(/\A\h{40}_/, "") }
  def ran(s, dir) = s.command_success?("test -e #{dir}/ran") ? s.read_file("#{dir}/ran").split("\n") : []

  def deployer(dir, **)
    described_class.new([system_host], app_path: "#{dir}/app", branch: "main", hooks_dir: hooks_dir, **)
  end

  # Origin with main and a side branch, an app clone, and hooks: "a" on main, "late" on a
  # later commit dated before "a", "side" on a branch that's not merged into main.
  # Two round trips (make_origin and one script): the repositories are scaffolding here,
  # not what's under test.
  def setup_app(s, dir)
    make_origin(s, dir)
    a, late, side = git_script(s, <<~SH, dir).split
      commit_in "$1" a file 2000000000
      commit_in "$1" late file 1000000000
      git -C "$1/dev" checkout --quiet -b side
      commit_in "$1" side file
      git -C "$1/dev" checkout --quiet main
      git clone --quiet -- "$1/origin.git" "$1/app"
    SH
    hook(a, "a", dir)
    hook(late, "late", dir)
    hook(side, "side", dir)
    { a: a, late: late, side: side }
  end

  it "runs hooks from the history of HEAD only, parents first, once" do
    with_system_session do |s, dir|
      setup_app(s, dir)

      results = deployer(dir).deploy
      expect(results.map { [it.status, short(it.applied)] }).to eq([[:ok, %w[a late]]])
      expect(ran(s, dir)).to eq(%w[a late])

      deployer(dir).deploy
      expect(ran(s, dir)).to eq(%w[a late])
    end
  end

  it "runs every hook of a commit that has several" do
    with_system_session do |s, dir|
      shas = setup_app(s, dir)
      hook(shas[:a], "a2", dir)

      deployer(dir).deploy

      expect(ran(s, dir)).to eq(%w[a a2 late])
    end
  end

  it "fails on checks returning false, leaves the hook unmarked and calls on_failure" do
    with_system_session do |s, dir|
      shas = setup_app(s, dir)
      hook(shas[:late], "late", dir, checks: false)
      calls = []
      d = deployer(dir)
      d.pre_pull { nil }
      d.on_failure { |phase, error| calls << [phase, error.class] }

      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect(e.results.map { [it.status, it.phase, short([it.hook]), short(it.applied)] })
          .to eq([[:failed, :hook, ["late"], ["a"]]])
      }
      expect(calls).to eq([[:hook, Herd::Deployer::CheckFailed]])
      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError)
      expect(ran(s, dir)).to eq(%w[a late late])
    end
  end

  it "fails the deploy when the health check fails, after the after block ran" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      d = deployer(dir)
      d.after { run("echo after >> #{dir}/ran") }
      d.check { raise "unhealthy" }

      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError, /check.*unhealthy/)
      expect(ran(s, dir).last).to eq("after")
    end
  end

  it "only lists pending hooks in a dry run: no lock, no tracking files, no after block" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      d = deployer(dir)
      d.after { run("echo after >> #{dir}/ran") }

      expect(d.check_hooks.map { short(it.pending) }).to eq([%w[a late]])
      expect(ran(s, dir)).to eq([])
      expect(s.file_exists?("~/.herd_deploy")).to be(false)
    end
  end

  it "refuses to start while another deploy holds the lock, and leaves that lock alone" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      deployer(dir).check_hooks(dry_run: false)
      lock = "#{tracking_of(s, dir)}/.lock"
      s.run("mkdir -- #{lock} && printf 'other-token\\nlaptop pid 1\\n' > #{lock}/owner", pty: false)

      expect { deployer(dir).deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect([e.results.first.status, e.results.first.error.message]).to match([:refused, /laptop pid 1/])
      }
      expect(s.run("head -n 1 #{lock}/owner", pty: false).strip).to eq("other-token")
    ensure
      s.run("rm -rf ~/.herd_deploy", pty: false)
    end
  end

  it "keeps the lock and reports :unknown when a hook's shell is killed" do
    with_system_session do |s, dir|
      shas = setup_app(s, dir)
      File.write(File.join(hooks_dir, "#{shas[:late]}_late.rb"), "actions { run('kill -9 $$') }\n")

      expect { deployer(dir).deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect([e.results.first.status, e.results.first.phase]).to eq(%i[unknown hook])
      }
      expect(s.file_exists?("#{tracking_of(s, dir)}/.lock")).to be(true)
    end
  end

  it "keeps the lock when on_failure times out after an ordinary failure" do
    with_system_session do |s, dir|
      shas = setup_app(s, dir)
      hook(shas[:late], "late", dir, checks: false)
      d = deployer(dir)
      d.pre_pull { nil }
      d.on_failure { |_phase, _error| run("sleep 5", timeout: 0.5) }

      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect([e.results.first.status, e.results.first.error.recovery_error.class])
          .to eq([:unknown, Herd::CommandTimeout])
      }
      expect(s.file_exists?("#{tracking_of(s, dir)}/.lock")).to be(true)
    end
  end

  it "doesn't report :ok or release the lock when the after block rescued a timeout" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      d = deployer(dir)
      d.after do
        run("sleep 5", timeout: 0.5)
      rescue Herd::CommandTimeout
        nil
      end

      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError) { |e| expect(e.results.first.status).to eq(:unknown) }
      expect(s.file_exists?("#{tracking_of(s, dir)}/.lock")).to be(true)
    end
  end

  it "doesn't mark a hook applied when it rescued a timeout in its actions" do
    with_system_session do |s, dir|
      shas = setup_app(s, dir)
      File.write(File.join(hooks_dir, "#{shas[:late]}_late.rb"), <<~RUBY)
        actions do
          run("sleep 5", timeout: 0.5)
        rescue Herd::CommandTimeout
          nil
        end
      RUBY

      expect { deployer(dir).deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect([e.results.first.status, e.results.first.applied.map { short([it]).first }]).to eq([:unknown, ["a"]])
      }
      expect(s.file_exists?("#{tracking_of(s, dir)}/#{shas[:late]}_late")).to be(false)
    end
  end

  it "refuses a dirty checkout before pre_pull, so nothing gets stopped" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      s.run("echo dirty >> #{dir}/app/README", pty: false)
      stopped = false
      d = deployer(dir)
      d.pre_pull { stopped = true }

      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError) { |e| expect(e.results.first.status).to eq(:refused) }
      expect(stopped).to be(false)
    ensure
      s.run("rm -rf ~/.herd_deploy", pty: false)
    end
  end

  it "resolves a relative app_path once, so git and hooks see the same directory" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      name = "herd-rel-#{SecureRandom.hex(3)}"
      s.run("mv -- #{s.shell_path("#{dir}/app")} ~/#{name}", pty: false)
      File.write(Dir[File.join(hooks_dir, "*_a.rb")].first, "actions { run('echo a >> #{dir}/ran') }\n")

      described_class.new([system_host], app_path: name, hooks_dir: hooks_dir).deploy

      expect(ran(s, dir)).to eq(%w[a late])
    ensure
      s.run("rm -rf ~/#{name} ~/.herd_deploy", pty: false)
    end
  end

  describe "a tracking directory of Herd before 2026-10 (~/.herd_deploy/<name>/)" do
    def legacy_with_marker(s, sha)
      s.run("mkdir -p ~/.herd_deploy/app && touch ~/.herd_deploy/app/#{sha}_a", pty: false)
    end

    it "is moved to the app's own directory on the first deploy, markers and all" do
      with_system_session do |s, dir|
        shas = setup_app(s, dir)
        legacy_with_marker(s, shas[:a])

        deployer(dir).deploy

        expect(ran(s, dir)).to eq(%w[late])
        expect(s.file_exists?("~/.herd_deploy/app")).to be(false)
        expect(s.file_exists?("#{tracking_of(s, dir)}/#{shas[:a]}_a")).to be(true)
        expect(File.basename(tracking_of(s, dir))).to match(/\Aapp-\h{12}\z/)
      end
    end

    it "counts in a dry run, which leaves it where it is" do
      with_system_session do |s, dir|
        shas = setup_app(s, dir)
        legacy_with_marker(s, shas[:a])

        expect(deployer(dir).check_hooks.map { short(it.pending) }).to eq([%w[late]])
        expect(s.file_exists?("~/.herd_deploy/app/#{shas[:a]}_a")).to be(true)
      end
    end

    it "goes to the first app deployed; another app with that name starts with its own" do
      with_system_session do |s, dir|
        shas = setup_app(s, dir)
        legacy_with_marker(s, shas[:a])
        s.run("mkdir -p #{dir}/other && git clone --quiet -- #{dir}/origin.git #{dir}/other/app", pty: false)

        deployer(dir).deploy
        described_class.new([system_host], app_path: "#{dir}/other/app", hooks_dir: hooks_dir).deploy

        expect(ran(s, dir)).to eq(%w[late a late])
      end
    end
  end

  it "keeps two apps with the same directory name apart, but refuses them one explicit app_id" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      s.run("mkdir -p #{dir}/other && git clone --quiet -- #{dir}/origin.git #{dir}/other/app", pty: false)
      other = lambda { |**opts|
        described_class.new([system_host], app_path: "#{dir}/other/app", hooks_dir: hooks_dir, **opts)
      }

      deployer(dir).deploy
      other.call.deploy
      expect(ran(s, dir)).to eq(%w[a late a late])

      deployer(dir, app_id: "shared").check_hooks(dry_run: false)
      expect { other.call(app_id: "shared").deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect([e.results.first.status, e.results.first.error.class])
          .to eq([:refused, Herd::Deployer::TrackingDirTaken])
      }
    end
  end

  it "reports a host it can't connect to without stopping the others" do
    with_system_session do |s, dir|
      setup_app(s, dir)
      dead = Herd::Host.new("127.0.0.1", { port: 1, user: "x", password: "x", timeout: 2 })
      d = described_class.new([system_host, dead], app_path: "#{dir}/app", hooks_dir: hooks_dir)

      expect { d.deploy }.to raise_error(Herd::Deployer::DeployError) { |e|
        expect(e.results.map { [it.status, it.phase] }).to eq([%i[ok done], %i[failed connect]])
      }
      expect(ran(s, dir)).to eq(%w[a late])
    ensure
      s.run("rm -rf ~/.herd_deploy", pty: false)
    end
  end
end
