# frozen_string_literal: true

RSpec.describe Herd::Commands::System do
  let(:session) { Herd::Session.new(nil, nil, "secret", log) }
  let(:output) do
    +"Europe/Paris
"
  end
  let(:log) { StringIO.new }

  before do
    allow(session).to receive(:run_result) { Herd::CommandResult.new(stdout: output, exit_code: 0) }
  end

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#system_timezone" do
    it "returns the stripped timezone" do
      expect(session.system_timezone).to eq("Europe/Paris")
    end

    it "is not cached — re-fetches on every call, since recipes may change the timezone mid-connection" do
      session.system_timezone
      session.system_timezone

      expect(session).to have_received(:run_result).twice
    end
  end
end
