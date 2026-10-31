# frozen_string_literal: true

# What the file commands do to real files is in spec/system/files_spec.rb.
RSpec.describe Herd::Commands::Files do
  let(:session) { Herd::Session.new(nil, nil, "secret", StringIO.new) }

  before { allow(session).to receive(:install_file).and_return(true) }

  it "passes sensitive: through the write helpers to install_file" do
    session.file("/etc/app.conf", "root", "root", content: "x", sensitive: true)
    session.write_to_file("/etc/app.conf", "x", sensitive: true)
    session.expect_file_content_equals("/etc/app.conf", "x", sensitive: true)

    expect(session).to have_received(:install_file).with(any_args, hash_including(sensitive: true)).exactly(3).times
  end
end
