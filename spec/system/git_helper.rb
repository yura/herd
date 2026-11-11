# frozen_string_literal: true

# Builds git repositories inside the container for spec/system: a bare origin, a "dev"
# clone to make commits in, and helpers to commit and push. Each helper is one bash
# script sent over stdin, so a commit costs one SSH round trip, not five.
module GitRepos
  GIT_ENV = <<~SH
    export GIT_AUTHOR_NAME=Herd GIT_AUTHOR_EMAIL=herd@example.com
    export GIT_COMMITTER_NAME=Herd GIT_COMMITTER_EMAIL=herd@example.com
  SH

  # commit_in DIR MESSAGE FILE [DATE]: appends MESSAGE to FILE in DIR/dev, commits, pushes,
  # prints the SHA. DATE (seconds) sets the commit's timestamp.
  COMMIT_FN = <<~'SH'
    commit_in() {
      if [ -n "${4:-}" ]; then
        export GIT_AUTHOR_DATE="@$4 +0000" GIT_COMMITTER_DATE="@$4 +0000"
      fi
      printf '%s\n' "$2" >> "$1/dev/$3"
      git -C "$1/dev" add -A
      git -C "$1/dev" commit --quiet -m "$2"
      git -C "$1/dev" push --quiet origin HEAD
      unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
      git -C "$1/dev" rev-parse HEAD
    }
  SH

  # Runs body with bash on the container, args as $1, $2, ...; returns stdout.
  def git_script(s, body, *)
    s.run("bash -s -- #{s.shell_args(*)}", pty: false, stdin: "set -eu\n#{GIT_ENV}#{COMMIT_FN}#{body}")
  end

  # Creates dir/origin.git with an initial commit on main and a dev clone at dir/dev.
  # Returns the origin URL.
  def make_origin(s, dir)
    git_script(s, <<~SH, dir)
      git init --quiet --bare --initial-branch=main -- "$1/origin.git"
      git clone --quiet -- "$1/origin.git" "$1/dev"
      commit_in "$1" initial README >/dev/null
    SH
    "#{dir}/origin.git"
  end

  # Commits a change to file in dir/dev on the current branch and pushes it.
  # date: sets the commit's timestamp (seconds). Returns the commit's SHA.
  def commit(s, dir, message, file: "file", date: nil)
    git_script(s, 'commit_in "$@"', dir, message, file, *date).strip
  end

  def git(s, args) = git_script(s, "git #{args}")
end

RSpec.configure { |config| config.include GitRepos, :system }
