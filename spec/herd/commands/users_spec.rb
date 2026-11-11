# frozen_string_literal: true

# What chpasswd receives and user lookups in a real shell are in spec/system/commands_spec.rb.
RSpec.describe Herd::Commands::Users do
  let(:session) { Herd::Session.new(host, nil, "secret", StringIO.new) }
  let(:host) { instance_double(Herd::Host, user: "someone_else", add_secret: nil) }
  let(:upload) { Herd::Transport::Upload.new(path: "/tmp/herd-upload.x", sensitive: true) }

  before do
    allow(session).to receive(:with_upload).and_yield(upload)
    allow(session).to receive(:sudo)
    allow(host).to receive(:password=)
  end

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#change_password" do
    it "uploads user:password as sensitive and feeds it to chpasswd as sensitive" do
      session.change_password("footbot", "s3cr3t Pass$9")

      expect(session).to have_received(:with_upload).with("footbot:s3cr3t Pass$9\n", sensitive: true)
      expect(session).to have_received(:sudo).with("chpasswd < /tmp/herd-upload.x", sensitive: true)
      expect(host).to have_received(:add_secret).with("s3cr3t Pass$9")
    end

    it "refuses input that would make chpasswd read another line" do
      expect { session.change_password("footbot", "a\nroot:x") }.to raise_error(ArgumentError)
      expect { session.change_password("foot:bot", "x") }.to raise_error(ArgumentError)
      expect(session).not_to have_received(:sudo)
    end

    it "updates host.password only when changing the SSH user's own password" do
      allow(host).to receive(:user).and_return("footbot")

      session.change_password("someoneelse", "a")
      expect(host).not_to have_received(:password=)

      session.change_password("footbot", "b")
      expect(host).to have_received(:password=).with("b")
    end
  end
end
