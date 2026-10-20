# frozen_string_literal: true

RSpec.describe Herd::Deployer do
  subject(:deployer) { described_class.new([], app_path: "~/app", branch: "main") }

  it "passes the block given to deploy on as the inline after step" do
    forwarded = nil
    allow(deployer).to receive(:run_deploy) { |**, &block| forwarded = block }
    step = proc { :restart }

    deployer.deploy(&step)

    expect(deployer).to have_received(:run_deploy).with(pull: true)
    expect(forwarded).to be(step)
  end
end
