# frozen_string_literal: true

RSpec.describe Herd::Commands::Git do
  let(:session) { Herd::Session.new(nil, mock_ssh_session, "secret", mock_log) }
  let(:mock_ssh_session) { instance_double(Net::SSH::Connection::Session) }
  let(:mock_log) { instance_double(File, puts: nil, print: nil, close: nil, flush: nil) }

  let(:path) { "~/projects/rbenv" }
  let(:url)  { "https://github.com/rbenv/rbenv.git" }

  it "is prepended into Session" do
    expect(Herd::Session.ancestors).to include(described_class)
  end

  describe "#git_repo" do
    context "when the repo isn't cloned yet" do
      before do
        allow(session).to receive(:file_exists?).with("#{path}/.git").and_return(false)
        allow(session).to receive(:run)
      end

      it "clones it" do
        session.git_repo(path, url, ref: "master")
        expect(session).to have_received(:run).with("git clone #{url} #{path}")
      end
    end

    context "when the repo is already cloned and clean" do
      before do
        allow(session).to receive(:file_exists?).with("#{path}/.git").and_return(true)
        allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return("")
        allow(session).to receive(:run).with("git -C #{path} pull origin master")
      end

      it "pulls the given ref instead of cloning" do
        session.git_repo(path, url, ref: "master")

        expect(session).to have_received(:run).with("git -C #{path} pull origin master")
        expect(session).not_to have_received(:run).with("git clone #{url} #{path}")
      end
    end

    context "when the repo has local changes" do
      before do
        allow(session).to receive(:file_exists?).with("#{path}/.git").and_return(true)
        allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return(" M some_file.rb\n")
        allow(session).to receive(:run).with("git -C #{path} pull origin master")
      end

      it "raises instead of pulling" do
        expect { session.git_repo(path, url, ref: "master") }
          .to raise_error(Herd::CommandError, /#{Regexp.escape(path)} has local changes/)

        expect(session).not_to have_received(:run).with("git -C #{path} pull origin master")
      end
    end
  end

  describe "#git_current_branch" do
    it "returns the stripped branch name" do
      allow(session).to receive(:run).with("git -C #{path} rev-parse --abbrev-ref HEAD").and_return("main\n")
      expect(session.git_current_branch(path)).to eq("main")
    end
  end

  describe "#git_dirty?" do
    it "is false when git status is empty" do
      allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return("")
      expect(session.git_dirty?(path)).to be false
    end

    it "is true when git status has output" do
      allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return(" M foo.rb\n")
      expect(session.git_dirty?(path)).to be true
    end

    it "ignores untracked files when ignore_untracked: true" do
      allow(session).to receive(:run).with("git -C #{path} status --porcelain --untracked-files=no").and_return("")
      expect(session.git_dirty?(path, ignore_untracked: true)).to be false
    end
  end

  describe "#git_pull" do
    it "pulls the tracked branch when no ref is given" do
      allow(session).to receive(:run).with("git -C #{path} pull")
      session.git_pull(path)
      expect(session).to have_received(:run).with("git -C #{path} pull")
    end

    it "pulls a specific ref when given" do
      allow(session).to receive(:run).with("git -C #{path} pull origin main")
      session.git_pull(path, ref: "main")
      expect(session).to have_received(:run).with("git -C #{path} pull origin main")
    end
  end

  describe "#git_commits_exist" do
    it "returns an empty array without running anything when given no shas" do
      allow(session).to receive(:run)
      expect(session.git_commits_exist(path)).to eq([])
      expect(session).not_to have_received(:run)
    end

    it "returns only the shas that are commits" do
      sha1 = "a" * 40
      sha2 = "b" * 40
      batch_check_output = <<~OUTPUT
        #{sha1} commit 123
        #{sha2} missing
      OUTPUT

      allow(session).to receive(:run)
        .with("printf '#{sha1}\\n#{sha2}' | git -C #{path} cat-file --batch-check")
        .and_return(batch_check_output)

      expect(session.git_commits_exist(path, sha1, sha2)).to eq([sha1])
    end
  end

  describe "#git_commit_time" do
    it "returns the commit timestamp as an integer" do
      sha = "a" * 40
      allow(session).to receive(:run).with("git -C #{path} log -1 --format=%ct #{sha}").and_return("1717000000\n")
      expect(session.git_commit_time(path, sha)).to eq(1_717_000_000)
    end
  end
end
