# frozen_string_literal: true

RSpec.describe Herd::Commands::Files do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  let(:path) { "/etc/app.conf" }

  before { allow(session).to receive(:write_to_file!) }

  describe "#expect_file_content_equals" do
    it "writes a missing file and returns true" do
      allow(session).to receive(:file_exists?).with(path).and_return(false)

      expect(session.expect_file_content_equals(path, "a = 1\n")).to be(true)
      expect(session).to have_received(:write_to_file!).with(path, "a = 1\n", sudo: true)
    end

    it "rewrites a file with different content and returns true" do
      allow(session).to receive(:file_exists?).with(path).and_return(true)
      allow(session).to receive(:read_file!).with(path, sudo: true).and_return("a = 0")

      expect(session.expect_file_content_equals(path, "a = 1\n")).to be(true)
      expect(session).to have_received(:write_to_file!)
    end

    it "leaves an identical file alone and returns false, ignoring the trailing newline" do
      allow(session).to receive(:file_exists?).with(path).and_return(true)
      allow(session).to receive(:read_file!).with(path, sudo: true).and_return("a = 1")

      expect(session.expect_file_content_equals(path, "a = 1\n")).to be(false)
      expect(session).not_to have_received(:write_to_file!)
    end
  end

  describe "#file" do
    before do
      allow(session).to receive(:file_user_and_group)
      allow(session).to receive(:file_permissions)
    end

    it "returns whether the content changed" do
      allow(session).to receive(:expect_file_content_equals).and_return(true, false)

      expect(session.file(path, "root", "root", content: "x")).to be(true)
      expect(session.file(path, "root", "root", content: "x")).to be(false)
    end

    it "still applies owner and mode when the content is unchanged" do
      allow(session).to receive(:expect_file_content_equals).and_return(false)

      session.file(path, "root", "root", content: "x", mode: 640)

      expect(session).to have_received(:file_user_and_group).with(path, "root", "root")
      expect(session).to have_received(:file_permissions).with(path, 640)
    end
  end
end
