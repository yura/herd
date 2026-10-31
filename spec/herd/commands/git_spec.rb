# frozen_string_literal: true

# What git does — clone, switch, fast-forward, refusals, hook history — is checked on real
# repositories in spec/system/git_spec.rb and spec/system/deployer_spec.rb.
RSpec.describe Herd::Commands::Git do
  let(:session) { Herd::Session.new(nil, nil, "secret", StringIO.new) }

  before { allow(session).to receive(:run).and_return("") }

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "branch names" do
    it "accepts branch names" do
      %w[main feature/x release-1.2 user@topic].each do |ref|
        expect { session.git_fetch("/srv/app", ref) }.not_to raise_error
      end
    end

    it "refuses options, ranges, shell syntax and what git check-ref-format rejects, before running anything" do
      ["-c core.x=y", "main..dev", "a//b", ".hidden", "a.lock", "x@{1}", "a b", "$(id)", "a;b", "a/"].each do |ref|
        expect { session.git_fetch("/srv/app", ref) }.to raise_error(ArgumentError)
        expect { session.git_sync!("/srv/app", ref) }.to raise_error(ArgumentError)
      end
      expect(session).not_to have_received(:run)
    end

    it "refuses a remote that isn't a plain name" do
      expect { session.git_sync!("/srv/app", "main", remote: "--upload-pack=x") }.to raise_error(ArgumentError)
    end
  end

  it "passes a path with spaces and shell syntax as one word, ~ as the SSH user's home" do
    session.git_fetch("~/my app $(id)", "main")

    expect(session).to have_received(:run).with(%(git -C "$HOME"/my\\ app\\ \\$\\(id\\) fetch --quiet origin +refs/heads/main:refs/remotes/origin/main))
  end

  describe "#git_lines" do
    it "splits on any line end and drops blank lines" do
      expect(session.git_lines("a\r\nb\n\n c \n")).to eq(%w[a b c])
    end
  end
end
