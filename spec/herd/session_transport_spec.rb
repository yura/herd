# frozen_string_literal: true

require_relative "../support/ssh_story"

# Session#channel_run against the real net-ssh Session and Channel; only the socket is scripted.
RSpec.describe Herd::Session, :ssh_story do
  let(:session) { described_class.new(nil, connection, "T0pS3kr3t", log) }
  let(:log) { StringIO.new }

  # Opens a channel the way run_result does and returns it for the rest of the story.
  def opens_command(server, command, pty: true, exec_success: true)
    channel = server.opens_channel
    sends_request_pty_with_reply(channel) if pty
    channel.sends_exec("set -o pipefail; #{command}", true, exec_success)
    channel
  end

  def finishes(channel, status = 0)
    channel.gets_exit_status(status)
    channel.gets_close
    channel.sends_close
  end

  it "answers a sudo prompt split across packets and keeps the output around it" do
    story do |server|
      channel = opens_command(server, "sudo -p 'HERD_SUDO: ' whoami")
      channel.gets_data("before\nHERD_")
      channel.inject_remote_delay!
      channel.gets_data("SUDO: ")
      channel.sends_data("T0pS3kr3t\n")
      channel.gets_data("\r\nroot\r\n")
      finishes(channel)
    end

    assert_scripted { expect(session.sudo("whoami")).to eq("before\nroot\r\n") }
  end

  it "accumulates stderr without replacing stdout" do
    story do |server|
      channel = opens_command(server, "make", pty: false)
      channel.gets_data("out")
      channel.gets_extended_data("err 1\n")
      channel.gets_extended_data("err 2\n")
      finishes(channel, 2)
    end

    assert_scripted do
      result = session.run_result("make", pty: false)
      expect([result.stdout, result.stderr, result.exit_code]).to eq(["out", "err 1\nerr 2\n", 2])
    end
  end

  it "raises when the server refuses the exec request" do
    story do |server|
      channel = opens_command(server, "true", exec_success: false)
      channel.gets_close
      channel.sends_close
    end

    assert_scripted do
      expect { session.run_result("true") }.to raise_error(Herd::CommandError, "could not execute command")
    end
  end

  it "raises when the channel closes without an exit status" do
    story do |server|
      channel = opens_command(server, "true")
      channel.gets_close
      channel.sends_close
    end

    assert_scripted do
      expect { session.run_result("true") }
        .to raise_error(Herd::CommandOutcomeUnknown, "channel closed without exit status")
    end
  end

  it "sends stdin and EOF on a PTY-less channel" do
    story do |server|
      channel = opens_command(server, "cat > /tmp/x", pty: false)
      channel.sends_data("line\nHERD_EOF\n")
      channel.sends_eof
      finishes(channel)
    end

    assert_scripted { session.run_result("cat > /tmp/x", pty: false, stdin: "line\nHERD_EOF\n") }
  end

  it "recognizes the prompt wherever the packets split it" do
    output = "before\nHERD_SUDO: \r\nroot\r\n"
    prompt_end = output.index("\r\nroot")

    (1...output.bytesize).each do |cut|
      @socket = @connection = @transport = nil
      story do |server|
        channel = opens_command(server, "sudo -p 'HERD_SUDO: ' whoami")
        # The password goes out as soon as the prompt is complete, before the rest arrives.
        if cut >= prompt_end
          channel.gets_data(output[0...cut])
          channel.sends_data("T0pS3kr3t\n")
          channel.gets_data(output[cut..])
        else
          channel.gets_data(output[0...cut])
          channel.inject_remote_delay!
          channel.gets_data(output[cut...prompt_end])
          channel.sends_data("T0pS3kr3t\n")
          channel.gets_data(output[prompt_end..])
        end
        finishes(channel)
      end

      assert_scripted do
        session = described_class.new(nil, connection, "T0pS3kr3t", log)
        expect(session.sudo("whoami")).to eq("before\nroot\r\n"), "split at #{cut}"
      end
    end
  end

  it "recognizes sudo's default prompt arriving one byte per packet" do
    story do |server|
      channel = opens_command(server, "sudo -p 'HERD_SUDO: ' whoami")
      # The password goes out on the last byte, so no delay follows it.
      "[sudo] password for herd: ".chars.each_with_index do |char, i|
        channel.inject_remote_delay! if i.positive?
        channel.gets_data(char)
      end
      channel.sends_data("T0pS3kr3t\n")
      channel.gets_data("\r\nroot\n")
      finishes(channel)
    end

    assert_scripted { expect(session.sudo("whoami")).to eq("root\n") }
  end

  it "closes the channel instead of answering a second prompt" do
    story do |server|
      channel = opens_command(server, "sudo -p 'HERD_SUDO: ' whoami")
      channel.gets_data("HERD_SUDO: ")
      channel.sends_data("T0pS3kr3t\n")
      channel.gets_data("\r\nSorry, try again.\r\nHERD_SUDO: ")
      channel.sends_close
      channel.gets_close
    end

    assert_scripted do
      expect { session.sudo("whoami") }.to raise_error(Herd::CommandError, "sudo: authentication failed")
    end
  end

  it "doesn't answer prompt text in the output of a command without sudo" do
    story do |server|
      channel = opens_command(server, "cat notes")
      channel.gets_data("HERD_SUDO: is a marker\n")
      finishes(channel)
    end

    assert_scripted { expect(session.run("cat notes")).to eq("HERD_SUDO: is a marker\n") }
  end

  it "raises when the server refuses the PTY" do
    story do |server|
      channel = server.opens_channel
      sends_request_pty_with_reply(channel, success: false)
    end

    assert_scripted { expect { session.run_result("true") }.to raise_error(Herd::CommandError, "could not obtain pty") }
  end

  it "closes the channel and raises CommandTimeout when nothing arrives by the deadline" do
    story do |server|
      channel = opens_command(server, "sleep 100")
      channel.sends_close
    end

    assert_scripted do
      expect { session.run_result("sleep 100", timeout: 0.05) }
        .to raise_error(Herd::CommandTimeout, /may still be running/)
    end
  end

  it "never sends the password to a command that merely mentions sudo and prints the prompt" do
    story do |server|
      channel = opens_command(server, "tail -n1 /var/log/sudo.log")
      channel.gets_data("HERD_SUDO: \n")
      finishes(channel)
    end

    # The story has no sends_data: a password sent here would fail it.
    assert_scripted { expect(session.run("tail -n1 /var/log/sudo.log")).to eq("HERD_SUDO: \n") }
  end
end
