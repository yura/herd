# frozen_string_literal: true

module Herd
  module Commands
    module Git
      # Clones the repo at path if it isn't there yet, otherwise pulls ref.
      # Refuses to pull over local changes rather than risk a silent merge.
      def git_repo(path, url, ref:)
        if file_exists?("#{path}/.git")
          raise Herd::CommandError, "git_repo: #{path} has local changes, refusing to pull" if git_dirty?(path)

          git_pull(path, ref: ref)
        else
          run("git clone #{url} #{path}")
        end
      end

      def git_current_branch(path)
        run("git -C #{path} rev-parse --abbrev-ref HEAD").strip
      end

      # ignore_untracked: true excludes untracked files from the dirty check
      # (e.g. servers that intentionally carry local scratch files).
      def git_dirty?(path, ignore_untracked: false)
        flags = ignore_untracked ? " --untracked-files=no" : ""
        !run("git -C #{path} status --porcelain#{flags}").strip.empty?
      end

      # ref: nil pulls whatever the current branch already tracks.
      def git_pull(path, ref: nil)
        ref ? run("git -C #{path} pull origin #{ref}") : run("git -C #{path} pull")
      end

      # Returns the subset of shas that exist in the repo's history as commits,
      # in one round trip instead of one lookup per sha.
      def git_commits_exist(path, *shas)
        return [] if shas.empty?

        run("printf '#{shas.join("\\n")}' | git -C #{path} cat-file --batch-check")
          .split(/\r?\n/).map(&:strip).reject(&:empty?)
          .select { |line| line.include?(" commit ") }
          .map    { |line| line.split.first }
      end

      def git_commit_time(path, sha)
        run("git -C #{path} log -1 --format=%ct #{sha}").strip.to_i
      end
    end
  end
end
