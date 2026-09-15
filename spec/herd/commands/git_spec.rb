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

    it "refuses a merge commit when ff_only: true" do
      allow(session).to receive(:run).with("git -C #{path} pull --ff-only origin main")
      session.git_pull(path, ref: "main", ff_only: true)
      expect(session).to have_received(:run).with("git -C #{path} pull --ff-only origin main")
    end
  end

  describe "#git_head_sha" do
    it "returns the stripped sha" do
      allow(session).to receive(:run).with("git -C #{path} rev-parse HEAD").and_return("#{"a" * 40}\n")
      expect(session.git_head_sha(path)).to eq("a" * 40)
    end
  end

  describe "#git_fetch" do
    it "fetches the whole remote when no ref is given" do
      allow(session).to receive(:run).with("git -C #{path} fetch --quiet origin")
      session.git_fetch(path)
      expect(session).to have_received(:run).with("git -C #{path} fetch --quiet origin")
    end

    it "fetches a single ref when given" do
      allow(session).to receive(:run).with("git -C #{path} fetch --quiet origin main")
      session.git_fetch(path, "main")
      expect(session).to have_received(:run).with("git -C #{path} fetch --quiet origin main")
    end
  end

  describe "#git_ahead_count" do
    it "returns the count as an integer" do
      allow(session).to receive(:run)
        .with("git -C #{path} rev-list --count origin/main..HEAD").and_return("2\n")
      expect(session.git_ahead_count(path, "main")).to eq(2)
    end
  end

  describe "#git_changed_files" do
    it "returns one entry per changed path" do
      allow(session).to receive(:run)
        .with("git -C #{path} diff --name-only aaa bbb").and_return("f-footbot/node.alloy\r\nREADME.md\n\n")
      expect(session.git_changed_files(path, "aaa", "bbb")).to eq(["f-footbot/node.alloy", "README.md"])
    end
  end

  describe "#git_tracked_files" do
    it "lists the tracked files" do
      allow(session).to receive(:run).with("git -C #{path} ls-files").and_return("a.rb\nb.rb\n")
      expect(session.git_tracked_files(path)).to eq(["a.rb", "b.rb"])
    end
  end

  describe "#git_sync!" do
    let(:old_sha) { "a" * 40 }
    let(:new_sha) { "b" * 40 }

    # A checkout that is clean, on `main`, and not ahead of origin.
    def stub_clean_checkout(ahead: "0", branch: "main")
      allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return("")
      allow(session).to receive(:run).with("git -C #{path} rev-parse --abbrev-ref HEAD").and_return("#{branch}\n")
      allow(session).to receive(:run).with("git -C #{path} fetch --quiet origin #{branch}")
      allow(session).to receive(:run)
        .with("git -C #{path} rev-list --count origin/#{branch}..HEAD").and_return("#{ahead}\n")
      allow(session).to receive(:run).with("git -C #{path} merge --ff-only origin/#{branch}")
    end

    context "when the checkout is already up to date" do
      before do
        stub_clean_checkout
        allow(session).to receive(:run).with("git -C #{path} rev-parse HEAD").and_return("#{old_sha}\n")
      end

      it "returns no changed files" do
        expect(session.git_sync!(path, "main")).to eq([])
      end
    end

    context "when the remote has moved on" do
      before do
        stub_clean_checkout
        allow(session).to receive(:run)
          .with("git -C #{path} rev-parse HEAD").and_return("#{old_sha}\n", "#{new_sha}\n")
        allow(session).to receive(:run)
          .with("git -C #{path} diff --name-only #{old_sha} #{new_sha}").and_return("f-footbot/node.alloy\n")
      end

      it "fast-forwards and returns the changed files" do
        expect(session.git_sync!(path, "main")).to eq(["f-footbot/node.alloy"])
        expect(session).to have_received(:run).with("git -C #{path} merge --ff-only origin/main")
      end

      it "yields before merging, so callers can stop services" do
        order = []
        allow(session).to receive(:run).with("git -C #{path} merge --ff-only origin/main") { order << :merge }

        session.git_sync!(path, "main") { order << :yield }

        expect(order).to eq(%i[yield merge])
      end
    end

    context "when the checkout has uncommitted changes" do
      before do
        allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return(" M f-footbot/node.alloy\n")
      end

      it "refuses to sync" do
        expect { session.git_sync!(path, "main") }
          .to raise_error(Herd::CommandError, /has uncommitted changes/)
      end

      it "does not yield, so services are left running" do
        expect { session.git_sync!(path, "main") { raise "must not be reached" } }
          .to raise_error(Herd::CommandError, /has uncommitted changes/)
      end
    end

    context "when the checkout is on another branch" do
      before do
        allow(session).to receive(:run).with("git -C #{path} status --porcelain").and_return("")
        allow(session).to receive(:run).with("git -C #{path} rev-parse --abbrev-ref HEAD").and_return("hotfix\n")
      end

      it "refuses by default" do
        expect { session.git_sync!(path, "main") }
          .to raise_error(Herd::CommandError, /is on 'hotfix', expected 'main'/)
      end

      it "refuses a detached HEAD even when strict_branch: false" do
        allow(session).to receive(:run).with("git -C #{path} rev-parse --abbrev-ref HEAD").and_return("HEAD\n")

        expect { session.git_sync!(path, "main", strict_branch: false) }
          .to raise_error(Herd::CommandError, /is in detached HEAD/)
      end

      it "follows the current branch when strict_branch: false" do
        allow(session).to receive(:info)
        allow(session).to receive(:run).with("git -C #{path} fetch --quiet origin hotfix")
        allow(session).to receive(:run)
          .with("git -C #{path} rev-list --count origin/hotfix..HEAD").and_return("0\n")
        allow(session).to receive(:run).with("git -C #{path} rev-parse HEAD").and_return("#{old_sha}\n")
        allow(session).to receive(:run).with("git -C #{path} merge --ff-only origin/hotfix")

        expect(session.git_sync!(path, "main", strict_branch: false)).to eq([])
        expect(session).to have_received(:run).with("git -C #{path} merge --ff-only origin/hotfix")
      end
    end

    # The case plain `git pull --ff-only` misses: it reports "Already up to date"
    # and exits 0, so a committed hand edit on the host would ship silently.
    context "when the checkout carries local commits" do
      before { stub_clean_checkout(ahead: "1") }

      it "refuses to sync" do
        expect { session.git_sync!(path, "main") }
          .to raise_error(Herd::CommandError, %r{has 1 local commit\(s\) not on origin/main})
      end

      it "does not yield, so services are left running" do
        expect { session.git_sync!(path, "main") { raise "must not be reached" } }
          .to raise_error(Herd::CommandError, /local commit/)
      end

      it "does not merge" do
        expect { session.git_sync!(path, "main") }.to raise_error(Herd::CommandError)
        expect(session).not_to have_received(:run).with("git -C #{path} merge --ff-only origin/main")
      end
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
