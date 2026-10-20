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

      # Fast-forwards path to remote/ref, refusing a dirty checkout, local commits
      # or a diverged branch. The block runs after those refusals but before the
      # merge — that's where callers stop services. Returns the changed files.
      def git_sync!(path, ref, remote: "origin", ignore_untracked: false, strict_branch: true)
        if git_dirty?(path, ignore_untracked: ignore_untracked)
          raise Herd::CommandError, "git_sync!: #{path} has uncommitted changes, refusing to sync"
        end

        ref = git_sync_ref(path, ref, strict_branch: strict_branch)

        git_fetch(path, ref, remote: remote)

        # `pull --ff-only` misses this: a checkout merely ahead of the remote
        # still fast-forwards, so committed hand edits would ship silently.
        ahead = git_ahead_count(path, ref, remote: remote)
        if ahead.positive?
          raise Herd::CommandError,
                "git_sync!: #{path} has #{ahead} local commit(s) not on #{remote}/#{ref}, refusing to sync"
        end

        yield if block_given?

        before = git_head_sha(path)
        run("git -C #{path} merge --ff-only #{remote}/#{ref}")
        after = git_head_sha(path)

        before == after ? [] : git_changed_files(path, before, after)
      end

      # The branch git_sync! actually syncs. strict_branch: false follows whatever
      # branch the host is on.
      def git_sync_ref(path, ref, strict_branch: true)
        branch = git_current_branch(path)
        return ref if branch == ref

        # Detached HEAD names no branch for the lax mode to follow — fatal either way.
        if branch == "HEAD"
          raise Herd::CommandError, "git_sync!: #{path} is in detached HEAD, expected '#{ref}', refusing to sync"
        end

        if strict_branch
          raise Herd::CommandError, "git_sync!: #{path} is on '#{branch}', expected '#{ref}', refusing to sync"
        end

        info("warning: #{path} is on '#{branch}', not '#{ref}' — syncing '#{branch}'")
        branch
      end

      def git_current_branch(path)
        run("git -C #{path} rev-parse --abbrev-ref HEAD").strip
      end

      def git_head_sha(path)
        run("git -C #{path} rev-parse HEAD").strip
      end

      # ignore_untracked: true excludes untracked files from the dirty check
      # (e.g. servers that intentionally carry local scratch files).
      def git_dirty?(path, ignore_untracked: false)
        flags = ignore_untracked ? " --untracked-files=no" : ""
        !run("git -C #{path} status --porcelain#{flags}").strip.empty?
      end

      def git_fetch(path, ref = nil, remote: "origin")
        run(["git -C #{path} fetch --quiet", remote, ref].compact.join(" "))
      end

      # Commits on the checkout that aren't on remote/ref. Needs a prior fetch.
      def git_ahead_count(path, ref, remote: "origin")
        run("git -C #{path} rev-list --count #{remote}/#{ref}..HEAD").strip.to_i
      end

      # ref: nil pulls whatever the current branch already tracks.
      # ff_only still accepts a checkout ahead of the remote — see git_sync!.
      def git_pull(path, ref: nil, ff_only: false)
        flags = ff_only ? " --ff-only" : ""
        ref ? run("git -C #{path} pull#{flags} origin #{ref}") : run("git -C #{path} pull#{flags}")
      end

      def git_changed_files(path, from, to)
        git_lines(run("git -C #{path} diff --name-only #{from} #{to}"))
      end

      def git_tracked_files(path)
        git_lines(run("git -C #{path} ls-files"))
      end

      # Returns the subset of shas that exist in the repo's history as commits,
      # in one round trip instead of one lookup per sha.
      def git_commits_exist(path, *shas)
        return [] if shas.empty?

        git_lines(run("printf '#{shas.join("\\n")}' | git -C #{path} cat-file --batch-check"))
          .select { |line| line.include?(" commit ") }
          .map    { |line| line.split.first }
      end

      def git_commit_time(path, sha)
        run("git -C #{path} log -1 --format=%ct #{sha}").strip.to_i
      end

      # Plumbing output is never colourised, so lines only need splitting and trimming.
      def git_lines(output)
        output.split(/\r?\n/).map(&:strip).reject(&:empty?)
      end
    end
  end
end
