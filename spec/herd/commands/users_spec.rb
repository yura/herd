# frozen_string_literal: true

require "open3"

RSpec.describe Herd::Commands::Users do
  let(:session) { Herd::Session.new(mock_host, mock_ssh_session, "secret", mock_log) }
  let(:mock_host) { instance_double(Herd::Host, user: "someone_else", password: "secret") }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_ssh_channel) { instance_double(Net::SSH::Connection::Channel) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }
  let(:captured_commands) { [] }

  before do
    allow(mock_ssh_session).to receive(:open_channel).and_yield(mock_ssh_channel)
    allow(mock_ssh_session).to receive(:loop)
    allow(mock_ssh_channel).to receive(:request_pty).and_yield(mock_ssh_channel, true)
    allow(mock_ssh_channel).to receive(:on_extended_data)
    allow(mock_ssh_channel).to receive(:on_request).with("exit-status")
                                                    .and_yield(nil, instance_double(Net::SSH::Buffer, read_long: 0))
    allow(mock_ssh_channel).to receive(:on_data).and_yield(nil, "")
    allow(mock_ssh_channel).to receive(:exec) do |cmd, &blk|
      captured_commands << cmd
      blk.call(mock_ssh_channel, nil)
    end
  end

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#user_exists?" do
    # Runs the real command through a shell: id's own output must not reach the comparison.
    before do
      allow(session).to receive(:run) { |cmd| Open3.capture2("bash", "-c", cmd).first }
    end

    it "is true for an existing user" do
      expect(session.user_exists?(Etc.getlogin || ENV.fetch("USER"))).to be(true)
    end

    it "is false for a missing user" do
      expect(session.user_exists?("herd_no_such_user")).to be(false)
    end
  end

  describe "#change_password" do
    # Regression test: a naive string-match spec (asserting the exact command
    # sent to Net::SSH) would just re-encode a quoting bug if the "expected"
    # string is wrong too. Instead, run the actual composed command through a
    # real shell and check the real password ends up on the far side of the
    # pipe, catching cases where the password variable is never expanded
    # (e.g. it stays as the literal `$HERD_PASS` text).
    it "expands the new password value into the chpasswd input, not the literal env var name" do
      session.change_password("footbot", "s3cr3tPass9")

      remote_command = captured_commands.last.sub(/\Aset -o pipefail; /, "")
      # swap the real `sudo ... chpasswd` (which needs root) for `cat`, so we
      # can inspect exactly what would have been piped to chpasswd.
      inspectable_command = remote_command.sub(/\|\s*sudo[^|]*chpasswd\s*\z/, "| cat")

      stdout, status = Open3.capture2("bash", "-c", inspectable_command)

      expect(status).to be_success
      expect(stdout.strip).to eq("footbot:s3cr3tPass9")
    end

    it "passes spaces, quotes and $() through to chpasswd literally" do
      password = %(alpha beta $(echo pwned) 'q" \\ end)
      session.change_password("footbot", password)

      inspectable_command = captured_commands.last.sub(/\Aset -o pipefail; /, "")
                                             .sub(/\|\s*sudo[^|]*chpasswd\s*\z/, "| cat")

      expect(Open3.capture2("bash", "-c", inspectable_command).first.chomp).to eq("footbot:#{password}")
    end

    it "updates host.password when changing the ssh user's own password" do
      host = instance_double(Herd::Host, user: "footbot")
      allow(host).to receive(:password=)
      session_with_host = Herd::Session.new(host, mock_ssh_session, "secret", mock_log)

      session_with_host.change_password("footbot", "s3cr3tPass9")

      expect(host).to have_received(:password=).with("s3cr3tPass9")
    end

    it "does not update host.password when changing a different user's password" do
      host = instance_double(Herd::Host, user: "footbot")
      allow(host).to receive(:password=)
      session_with_host = Herd::Session.new(host, mock_ssh_session, "secret", mock_log)

      session_with_host.change_password("someoneelse", "s3cr3tPass9")

      expect(host).not_to have_received(:password=)
    end
  end
end
