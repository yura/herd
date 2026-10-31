# frozen_string_literal: true

# Builds git repositories inside the container for spec/system: a bare origin, a "dev"
# clone to make commits in, and helpers to commit and push.
module GitRepos
  GIT_ENV = { "GIT_AUTHOR_NAME" => "Herd", "GIT_AUTHOR_EMAIL" => "herd@example.com",
              "GIT_COMMITTER_NAME" => "Herd", "GIT_COMMITTER_EMAIL" => "herd@example.com" }.freeze

  # Creates dir/origin.git with an initial commit on main and a dev clone at dir/dev.
  # Returns the origin URL.
  def make_origin(s, dir)
    origin = "#{dir}/origin.git"
    git(s, "init --quiet --bare --initial-branch=main -- #{s.shell_path(origin)}")
    git(s, "clone --quiet -- #{s.shell_path(origin)} #{s.shell_path("#{dir}/dev")}")
    commit(s, dir, "initial", file: "README")
    origin
  end

  # Commits a change to file in dir/dev on the current branch and pushes it.
  # date: sets the commit's timestamp (seconds). Returns the commit's SHA.
  def commit(s, dir, message, file: "file", date: nil)
    dev = "#{dir}/dev"
    env = if date
            GIT_ENV.merge("GIT_COMMITTER_DATE" => "@#{date} +0000",
                          "GIT_AUTHOR_DATE" => "@#{date} +0000")
          else
            GIT_ENV
          end
    s.with_env(env.transform_values(&:shellescape)) do
      s.run("printf '%s\\n' #{s.shell_args(message)} >> #{s.shell_path("#{dev}/#{file}")}", pty: false)
      git(s, "-C #{s.shell_path(dev)} add -A")
      git(s, "-C #{s.shell_path(dev)} commit --quiet -m #{s.shell_args(message)}")
    end
    git(s, "-C #{s.shell_path(dev)} push --quiet origin HEAD")
    git(s, "-C #{s.shell_path(dev)} rev-parse HEAD").strip
  end

  def git(s, args) = s.with_env(GIT_ENV.transform_values(&:shellescape)) { s.run("git #{args}", pty: false) }
end

RSpec.configure { |config| config.include GitRepos, :system }
