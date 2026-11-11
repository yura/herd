# frozen_string_literal: true

require "net/ssh/test"

# Net::SSH::Test for RSpec: a real Net::SSH::Connection::Session over a scripted socket.
# Describe the exchange with story, then run the code inside assert_scripted, which
# fails if the code didn't go through every scripted event:
#
#   story do |server|
#     channel = server.opens_channel
#     channel.sends_request_pty
#     channel.sends_exec("set -o pipefail; hostname")
#     channel.gets_data("alpha\n")
#     channel.gets_exit_status(0)
#     channel.gets_close
#     channel.sends_close
#   end
#   assert_scripted { session.run("hostname") }
module SSHStory
  include Net::SSH::Test

  # Net::SSH::Test::Channel#sends_request_pty scripts the request without a reply, but
  # Channel#request_pty with a block (as Session#channel_run calls it) asks for one.
  # success: false scripts the server refusing the PTY.
  def sends_request_pty_with_reply(channel, success: true)
    pty = Net::SSH::Connection::Channel::VALID_PTY_OPTIONS.merge(modes: "\0").values
    channel.script.sends_channel_request(channel, "pty-req", true, pty, success)
  end

  # The assertion assert_scripted makes, in RSpec terms.
  def assert(condition, message = nil)
    expect(condition).to be(true), message
  end
end

RSpec.configure do |config|
  config.include SSHStory, :ssh_story
end
