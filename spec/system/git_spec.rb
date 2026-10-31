# frozen_string_literal: true

require_relative "system_helper"
require_relative "git_helper"

RSpec.describe Herd::Commands::Git, :system do
  def branch(s, path) = s.git_current_branch(path)

  describe "#git_repo" do
    it "clones on the given branch into a path with spaces" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        git(s, "-C #{s.shell_path("#{dir}/dev")} checkout --quiet -b release")
        commit(s, dir, "on release")

        expect(s.git_repo("#{dir}/my app", origin, ref: "release")).to eq([])
        expect(branch(s, "#{dir}/my app")).to eq("release")
      end
    end

    it "switches an existing checkout to ref and fast-forwards it" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        s.git_repo("#{dir}/app", origin, ref: "main")
        git(s, "-C #{s.shell_path("#{dir}/dev")} checkout --quiet -b release")
        commit(s, dir, "on release", file: "release.txt")

        expect(s.git_repo("#{dir}/app", origin, ref: "release")).to eq(["release.txt"])
        expect(branch(s, "#{dir}/app")).to eq("release")
      end
    end

    it "switches a single-branch clone, whose fetch config only knows its own branch" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        git(s, "-C #{s.shell_path("#{dir}/dev")} checkout --quiet -b release")
        commit(s, dir, "on release", file: "release.txt")
        git(s, "clone --quiet --single-branch --branch main -- #{s.shell_path(origin)} #{s.shell_path("#{dir}/app")}")

        expect(s.git_repo("#{dir}/app", origin, ref: "release")).to eq(["release.txt"])
        expect(branch(s, "#{dir}/app")).to eq("release")
      end
    end

    it "refuses to switch to a local branch that has commits not on origin, before checking out" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        git(s, "-C #{s.shell_path("#{dir}/dev")} checkout --quiet -b release")
        commit(s, dir, "on release")
        git(s, "-C #{s.shell_path("#{dir}/dev")} checkout --quiet main")
        s.git_repo("#{dir}/app", origin, ref: "main")
        app = s.shell_path("#{dir}/app")
        git(s, "-C #{app} branch --quiet release origin/release")
        git(s, "-C #{app} checkout --quiet release")
        s.run("echo local >> #{s.shell_path("#{dir}/app/README")}", pty: false)
        git(s, "-C #{app} commit --quiet -am 'hand edit'")
        git(s, "-C #{app} checkout --quiet main")

        expect do
          s.git_repo("#{dir}/app", origin, ref: "release")
        end.to raise_error(Herd::CommandError, /local release has commits/)
        expect(branch(s, "#{dir}/app")).to eq("main")
      end
    end

    it "refuses a checkout of another repository" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        s.git_repo("#{dir}/app", origin, ref: "main")

        expect do
          s.git_repo("#{dir}/app", "#{dir}/other.git", ref: "main")
        end.to raise_error(Herd::CommandError, /origin/)
      end
    end

    it "refuses refs that aren't branch names before running anything" do
      with_system_session do |s, dir|
        ["-c x", "main..dev", "$(touch #{dir}/pwned)", "v1 x"].each do |ref|
          expect { s.git_repo("#{dir}/app", "x", ref: ref) }.to raise_error(ArgumentError)
        end
        expect(s.file_exists?("#{dir}/pwned")).to be(false)
      end
    end
  end

  describe "#git_sync!" do
    it "refuses local commits and yields only after the refusals" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        s.git_repo("#{dir}/app", origin, ref: "main")
        s.run("echo local >> #{s.shell_path("#{dir}/app/README")}", pty: false)
        git(s, "-C #{s.shell_path("#{dir}/app")} commit --quiet -am 'hand edit'")
        yielded = false

        expect do
          s.git_sync!("#{dir}/app", "main") do
            yielded = true
          end
        end.to raise_error(Herd::CommandError, /local commit/)
        expect(yielded).to be(false)
      end
    end

    it "refuses before yielding when the branch is missing on the remote" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        s.git_repo("#{dir}/app", origin, ref: "main")
        git(s, "-C #{s.shell_path("#{dir}/app")} checkout --quiet -b nope") # local only, not on origin
        yielded = false

        expect { s.git_sync!("#{dir}/app", "nope") { yielded = true } }
          .to raise_error(Herd::CommandError, /couldn't find remote ref/)
        expect(yielded).to be(false)
      end
    end

    it "refuses before yielding when the branch to switch to has local commits" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        git(s, "-C #{s.shell_path("#{dir}/dev")} checkout --quiet -b release")
        commit(s, dir, "on release")
        s.git_repo("#{dir}/app", origin, ref: "release")
        commit_script = 'echo x >> "$1/README" && git -C "$1" commit --quiet -am local && git -C "$1" checkout --quiet main'
        git_script(s, commit_script, "#{dir}/app")
        yielded = false

        expect { s.git_sync!("#{dir}/app", "release", switch_branch: true) { yielded = true } }
          .to raise_error(Herd::CommandError, /local release has commits/)
        expect(yielded).to be(false)
      end
    end

    it "returns changed paths as they are, spaces and all, with git's own output kept out" do
      with_system_session do |s, dir|
        origin = make_origin(s, dir)
        s.git_repo("#{dir}/app", origin, ref: "main")
        commit(s, dir, "spaced", file: "my file.txt")

        expect(s.git_sync!("#{dir}/app", "main")).to eq(["my file.txt"])
      end
    end
  end
end
