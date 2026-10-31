# frozen_string_literal: true

# Deploys against real repositories are in spec/system/deployer_spec.rb.
RSpec.describe Herd::Deployer do
  subject(:deployer) { described_class.new([], app_path: "~/app", branch: "main") }

  it "passes the block given to deploy on as the inline after step" do
    forwarded = nil
    allow(deployer).to receive(:run_deploy) { |**, &block| forwarded = block }
    step = proc { :restart }

    deployer.deploy(&step)

    expect(deployer).to have_received(:run_deploy).with(pull: true, dry_run: false)
    expect(forwarded).to be(step)
  end

  it "runs check_hooks as a dry run unless told otherwise" do
    allow(deployer).to receive(:run_deploy)

    deployer.check_hooks
    deployer.check_hooks(dry_run: false)

    expect(deployer).to have_received(:run_deploy).with(pull: false, dry_run: true).ordered
    expect(deployer).to have_received(:run_deploy).with(pull: false, dry_run: false).ordered
  end

  it "refuses an app_id that isn't a plain directory name, . and .. included" do
    ["../x", ".", "..", "a b", ""].each do |app_id|
      expect { described_class.new([], app_path: "~/app", app_id: app_id) }.to raise_error(ArgumentError)
    end
  end

  describe "a host whose Host#exec raised" do
    let(:host) { Herd::Host.new("10.0.0.9", user: "deploy") }
    let(:runner) { Herd::Runner.new([host]) }
    let(:deployer) { described_class.new(runner, app_path: "~/app") }

    def failing_run(error)
      allow(runner).to receive(:exec_results).and_return([[host, nil, error]])
      deployer.deploy
    rescue Herd::Deployer::DeployError => e
      e.results.first
    end

    it "is reported as interrupted, with the phase it was in, when the connection broke midway" do
      allow(runner).to receive(:exec_results) do
        deployer.instance_variable_get(:@states)[host] =
          Herd::Deployer::State.new(:hook, "abc_x", ["abc_w"], false, true)
        [[host, nil, Net::SSH::Disconnect.new("connection closed")]]
      end

      result = nil
      expect { deployer.deploy }.to raise_error(Herd::Deployer::DeployError) { |e| result = e.results.first }
        .and output(/\[10.0.0.9\] deploy interrupted in hook/).to_stdout
      expect([result.status, result.phase, result.hook, result.applied]).to eq([:unknown, :hook, "abc_x", ["abc_w"]])
    end

    it "is a failed connection, not an interruption, even after an earlier run of the same deployer" do
      deployer.instance_variable_get(:@states)[host] = Herd::Deployer::State.new(:done, nil, ["abc_w"], false, false)

      result = failing_run(Herd::CommandError.new("connection refused"))

      expect([result.status, result.phase, result.applied]).to eq([:failed, :connect, []])
    end
  end

  describe Herd::Deployer::DeployError do
    it "names each host that didn't finish, with its status and phase" do
      host = instance_double(Herd::Host, host: "web1")
      ok   = Herd::Deployer::DeployResult.new(instance_double(Herd::Host, host: "web2"), :ok, :done, nil, [], [], nil)
      bad  = Herd::Deployer::DeployResult.new(host, :failed, :check, nil, [], [], RuntimeError.new("unhealthy"))

      error = described_class.new([ok, bad])

      expect(error.message).to eq("web1: failed in check: unhealthy")
      expect(error.results).to eq([ok, bad])
    end
  end
end
