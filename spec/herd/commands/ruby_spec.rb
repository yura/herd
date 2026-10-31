# frozen_string_literal: true

RSpec.describe Herd::Commands::Ruby do
  let(:session) { Herd::Session.new(nil, nil, "secret", StringIO.new) }

  before { allow(session).to receive(:run).and_return("") }

  it "passes each bundle argument as one word" do
    session.bundle("install", "--without", "development", "test")

    expect(session).to have_received(:run).with("~/.rbenv/shims/bundle install --without development test")
  end

  it "keeps Ruby code with spaces, parentheses and quotes as one rails argument" do
    session.rails("runner", %(User.where(name: "a b").count), env: "staging")

    expect(session).to have_received(:run)
      .with(%(RAILS_ENV=staging ~/.rbenv/shims/rails runner User.where\\(name:\\ \\"a\\ b\\"\\).count))
  end

  it "doesn't split one string into several words" do
    session.rake("db:migrate VERSION=1")

    expect(session).to have_received(:run).with("RAILS_ENV=production ~/.rbenv/shims/rake db:migrate\\ VERSION\\=1")
  end
end
