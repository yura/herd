# frozen_string_literal: true

RSpec.describe Herd::Commands::System do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  before do
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)
    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:on_extended_data)
    allow(mock_ssh_channel).to receive(:on_request).with("exit-status")
                                                   .and_yield(nil, instance_double(Net::SSH::Buffer, read_long: 0))
    allow(mock_ssh_channel).to receive(:exec)
      .with("set -o pipefail; cat /etc/timezone")
      .and_yield(mock_ssh_channel, nil)
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "Europe/Paris\n")
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

      expect(mock_ssh_channel).to have_received(:exec).twice
    end
  end
end
