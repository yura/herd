# frozen_string_literal: true

module Herd
  module Commands
    # Paths go through shell_path; refs must be branch names (see git_branch!) and remotes
    # plain names, both checked before anything runs on the host.
    module Git
      # What `git check-ref-format --branch` accepts, minus a leading "-" (it would read as
      # an option): no "..", "//", "@{", control characters, components starting with "."
      # or ending in ".lock", and no trailing "/" or ".".
      BRANCH = %r{\A(?!-)(?!.*(?:\.\.|//|@\{|\.lock(?:/|\z)|(?:\A|/)\.))[A-Za-z0-9._/@+-]+(?<![/.])\z}
      REMOTE = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

      # Makes path a checkout of url on branch ref, fast-forwarded to origin/ref, cloning
      # it if missing. Every refusal comes before anything changes: a different origin URL,
      # local changes, a missing origin/ref (fetch fails), a local ref with its own commits.
      # Returns the changed files ([] after a clone).
      def git_repo(path, url, ref:)
        git_branch!(ref)
        unless file_exists?("#{path}/.git")
          run("git clone --branch #{shell_args(ref)} -- #{shell_args(url)} #{shell_path(path)}")
          return []
        end

        origin = run("#{git(path)} remote get-url origin", pty: false).strip
        raise Herd::CommandError, "git_repo: #{path} has origin #{origin}, expected #{url}" if origin != url

        git_sync!(path, ref, switch_branch: true)
      end

      # Fast-forwards path to remote/ref, refusing a dirty checkout, local commits
      # or a diverged branch. The block runs after those refusals but before the
      # merge — that's where callers stop services. Returns the changed files.
      #
      # strict_branch: false follows whatever branch the host is on. switch_branch: true
      # checks out ref instead, after making sure the local ref has no commits of its own.
      def git_sync!(path, ref, remote: "origin", ignore_untracked: false, strict_branch: true, switch_branch: false)
        git_branch!(ref)
        raise ArgumentError, "git: invalid remote name #{remote.inspect}" unless remote.match?(REMOTE)
        if git_dirty?(path, ignore_untracked: ignore_untracked)
          raise Herd::CommandError, "git_sync!: #{path} has uncommitted changes, refusing to sync"
        end

        current = git_current_branch(path)
        ref     = git_sync_ref(path, ref, strict_branch: strict_branch) unless switch_branch

        git_fetch(path, ref, remote: remote)
        unless command_success?("#{git(path)} rev-parse --verify --quiet #{shell_args("#{git_remote_ref(remote, ref)}^{commit}")}",
                                pty: false)
          raise Herd::CommandError, "git_sync!: #{git_remote_ref(remote, ref)} is missing after fetch, refusing to sync"
        end

        switch = switch_branch && current != ref
        if switch
          # After checkout, merge --ff-only would accept a local ref that is ahead of remote/ref.
          git_refuse_local_commits!(path, ref, remote: remote)
        else
          # `pull --ff-only` misses this: a checkout merely ahead of the remote
          # still fast-forwards, so committed hand edits would ship silently.
          ahead = git_ahead_count(path, ref, remote: remote)
          if ahead.positive?
            raise Herd::CommandError,
                  "git_sync!: #{path} has #{ahead} local commit(s) not on #{remote}/#{ref}, refusing to sync"
          end
        end

        yield if block_given?

        before = git_head_sha(path)
        git_checkout(path, ref, remote: remote) if switch
        run("#{git(path)} merge --ff-only #{shell_args(git_remote_ref(remote, ref))}")
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
        run("#{git(path)} rev-parse --abbrev-ref HEAD", pty: false).strip
      end

      def git_head_sha(path)
        run("#{git(path)} rev-parse HEAD", pty: false).strip
      end

      # ignore_untracked: true excludes untracked files from the dirty check
      # (e.g. servers that intentionally carry local scratch files).
      def git_dirty?(path, ignore_untracked: false)
        flags = ignore_untracked ? " --untracked-files=no" : ""
        !run("#{git(path)} status --porcelain#{flags}", pty: false).strip.empty?
      end

      # With ref, fetches that branch into refs/remotes/<remote>/<ref> through an explicit
      # refspec: a single-branch or shallow clone's remote.<remote>.fetch would only update
      # FETCH_HEAD, leaving the remote-tracking ref missing or stale.
      def git_fetch(path, ref = nil, remote: "origin")
        return run("#{git(path)} fetch --quiet #{shell_args(remote)}") unless ref

        git_branch!(ref)
        run("#{git(path)} fetch --quiet #{shell_args(remote, "+refs/heads/#{ref}:#{git_remote_ref(remote, ref)}")}")
      end

      # Commits on the checkout that aren't on remote/ref. Needs a prior fetch.
      def git_ahead_count(path, ref, remote: "origin")
        run("#{git(path)} rev-list --count #{shell_args("#{git_remote_ref(remote, ref)}..HEAD")}",
            pty: false).strip.to_i
      end

      # ref: nil pulls whatever the current branch already tracks.
      # ff_only still accepts a checkout ahead of the remote — see git_sync!.
      def git_pull(path, ref: nil, ff_only: false)
        git_branch!(ref) if ref
        flags = ff_only ? " --ff-only" : ""
        ref ? run("#{git(path)} pull#{flags} origin #{shell_args(ref)}") : run("#{git(path)} pull#{flags}")
      end

      def git_changed_files(path, from, to)
        git_lines(run("#{git(path)} diff --name-only #{shell_args(from, to)}", pty: false))
      end

      def git_tracked_files(path)
        git_lines(run("#{git(path)} ls-files", pty: false))
      end

      # Every commit reachable from HEAD, parents before children (topological order).
      # A failure of git raises; it never reads as an empty history.
      def git_history(path)
        git_lines(run("#{git(path)} rev-list --topo-order --reverse HEAD", pty: false))
      end

      # Plumbing output is never colourised, so lines only need splitting and trimming.
      def git_lines(output)
        output.split(/\r?\n/).map(&:strip).reject(&:empty?)
      end

      private

      def git(path) = "git -C #{shell_path(path)}"

      # Full ref names only: a short "origin/main" depends on what refs and config the clone has.
      def git_remote_ref(remote, ref) = "refs/remotes/#{remote}/#{ref}"

      def git_branch!(ref)
        return if ref.to_s.match?(BRANCH)

        raise ArgumentError,
              "git: #{ref.inspect} is not a branch name (tags and SHAs aren't supported)"
      end

      # Raises if the local branch exists and has commits that aren't on remote/branch.
      def git_refuse_local_commits!(path, branch, remote:)
        return unless command_success?("#{git(path)} show-ref --verify --quiet #{shell_args("refs/heads/#{branch}")}",
                                       pty: false)

        base   = git_remote_ref(remote, branch)
        result = run_result("#{git(path)} merge-base --is-ancestor #{shell_args("refs/heads/#{branch}", base)}",
                            pty: false)
        return if result.success?
        raise Herd::CommandError, "git: merge-base failed: #{result.stderr.strip}" unless result.exit_code == 1

        raise Herd::CommandError, "git_sync!: #{path}: local #{branch} has commits not on #{base}, refusing to sync"
      end

      def git_checkout(path, ref, remote:)
        local = command_success?("#{git(path)} show-ref --verify --quiet #{shell_args("refs/heads/#{ref}")}",
                                 pty: false)
        if local
          run("#{git(path)} checkout --quiet #{shell_args(ref)} --")
        else
          # --no-track: tracking needs the remote's fetch config to cover the branch, which a
          # single-branch clone's doesn't; Herd compares against the full remote ref anyway.
          run("#{git(path)} checkout --quiet --no-track -b #{shell_args(ref)} #{shell_args(git_remote_ref(remote,
                                                                                                          ref))}")
        end
      end
    end
  end
end
