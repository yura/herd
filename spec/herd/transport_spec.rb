# frozen_string_literal: true

# Real uploads and reads over SSH are in spec/system; here only what Session does around them.
RSpec.describe Herd::Transport do
  let(:session) { Herd::Session.new(nil, nil, "secret", log) }
  let(:log) { StringIO.new }
  let(:upload) { Herd::Transport::Upload.new(path: "/tmp/herd-upload.x", sensitive: true) }

  before do
    allow(session).to receive(:upload).and_return(upload)
    allow(session).to receive(:info)
  end

  def answer(stdout, exit_code: 0)
    Herd::CommandResult.new(stdout: stdout, exit_code: exit_code)
  end

  it "logs every command inside a sensitive upload's block as sensitive, errors included" do
    allow(session).to receive(:ssh_execute) do |command, **|
      command.start_with?("psql") ? answer("psql: ERROR near 'hunter22'", exit_code: 3) : answer("")
    end

    expect { session.with_upload("hunter22", sensitive: true) { |f| session.run("psql -f - < #{f.shell_path}") } }
      .to raise_error(Herd::CommandError) { |e| expect(e.message).not_to include("hunter22") }
    expect(log.string).not_to include("hunter22")

    session.run("echo after")
    expect(log.string).to include('"command":"echo after"')
  end

  it "attaches a failed removal to the block's error instead of replacing it" do
    allow(session).to receive(:ssh_execute) do |command, **|
      command.start_with?("rm ") ? answer("", exit_code: 1) : answer("")
    end

    expect { session.with_upload("x") { raise ArgumentError, "block failed" } }
      .to raise_error(ArgumentError, "block failed") { |e|
            expect(e.cleanup_errors.first.message).to include("could not remove")
          }
  end

  it "returns the block's value and removes the file" do
    allow(session).to receive(:ssh_execute).and_return(answer(""))

    expect(session.with_upload("x") { :value }).to eq(:value)
    expect(session).to have_received(:ssh_execute).with("rm -f -- /tmp/herd-upload.x", any_args)
  end
end
