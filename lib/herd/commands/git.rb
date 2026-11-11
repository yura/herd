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

        # Three round trips: inspect, fetch and check, apply. Everything that can refuse
        # happens in the first two, before the block (which may stop services).
        current, dirty = git_inspect(path, ignore_untracked: ignore_untracked)
        raise Herd::CommandError, "git_sync!: #{path} has uncommitted changes, refusing to sync" if dirty

        ref    = git_follow_ref(path, ref, current, strict_branch: strict_branch) unless switch_branch
        switch = switch_branch && current != ref
        git_fetch_and_check(path, ref, remote: remote, switch: switch)

        yield if block_given?

        git_apply(path, ref, remote: remote, switch: switch)
      end

      # The branch git_sync! actually syncs. strict_branch: false follows whatever
      # branch the host is on.
      def git_sync_ref(path, ref, strict_branch: true)
        git_follow_ref(path, ref, git_current_branch(path), strict_branch: strict_branch)
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

      # Exit codes of the git_sync! scripts for refusals; anything else is git's own failure.
      SYNC_REF_MISSING  = 10
      SYNC_LOCAL_AHEAD  = 11

      # [current branch ("HEAD" when detached), dirty?] in one round trip.
      def git_inspect(path, ignore_untracked:)
        script = <<~SH
          set -eu
          git -C "$1" rev-parse --abbrev-ref HEAD
          status=$(git -C "$1" status --porcelain ${2:+"$2"})
          if [ -n "$status" ]; then echo dirty; else echo clean; fi
        SH
        flags = ignore_untracked ? "--untracked-files=no" : ""
        branch, state = run("bash -c #{script.shellescape} _ #{shell_path(path)} #{shell_args(flags)}", pty: false)
                        .split("\n").map(&:strip)
        [branch, state == "dirty"]
      end

      # The rule of git_sync_ref, given the current branch.
      def git_follow_ref(path, ref, branch, strict_branch:)
        return ref if branch == ref

        # Detached HEAD names no branch for the lax mode to follow — fatal either way.
        if branch == "HEAD"
          raise Herd::CommandError, "git_sync!: #{path} is in detached HEAD, expected '#{ref}', refusing to sync"
        end
        if strict_branch
          raise Herd::CommandError,
                "git_sync!: #{path} is on '#{branch}', expected '#{ref}', refusing to sync"
        end

        info("warning: #{path} is on '#{branch}', not '#{ref}' — syncing '#{branch}'")
        branch
      end

      # Fetches ref into its remote-tracking ref and runs every check that must pass before
      # the working tree changes, in one round trip. Refusals exit with their own codes.
      def git_fetch_and_check(path, ref, remote:, switch:)
        script = <<~SH
          set -eu
          remote_ref="refs/remotes/$2/$3"
          git -C "$1" fetch --quiet "$2" "+refs/heads/$3:$remote_ref"
          git -C "$1" rev-parse --verify --quiet "$remote_ref^{commit}" >/dev/null || exit #{SYNC_REF_MISSING}
          if [ "$4" = switch ]; then
            # After checkout, merge --ff-only would accept a local ref that is ahead of remote/ref.
            git -C "$1" show-ref --verify --quiet "refs/heads/$3" || exit 0
            status=0
            git -C "$1" merge-base --is-ancestor "refs/heads/$3" "$remote_ref" || status=$?
            [ "$status" -ne 1 ] || exit #{SYNC_LOCAL_AHEAD}
            exit "$status"
          fi
          # pull --ff-only misses this: a checkout merely ahead of the remote still
          # fast-forwards, so committed hand edits would ship silently.
          ahead=$(git -C "$1" rev-list --count "$remote_ref..HEAD")
          [ "$ahead" -eq 0 ] || { echo "$ahead"; exit #{SYNC_LOCAL_AHEAD}; }
        SH
        result = run_result("bash -c #{script.shellescape} _ #{shell_path(path)} #{shell_args(remote, ref, switch ? "switch" : "stay")}",
                            pty: false)
        return if result.success?

        case result.exit_code
        when SYNC_REF_MISSING
          raise Herd::CommandError, "git_sync!: #{git_remote_ref(remote, ref)} is missing after fetch, refusing to sync"
        when SYNC_LOCAL_AHEAD
          if switch
            raise Herd::CommandError,
                  "git_sync!: #{path}: local #{ref} has commits not on #{git_remote_ref(remote,
                                                                                        ref)}, refusing to sync"
          end

          raise Herd::CommandError,
                "git_sync!: #{path} has #{result.stdout.strip} local commit(s) not on #{remote}/#{ref}, refusing to sync"
        else
          raise Herd::CommandError, "git_sync!: #{result.stderr.strip} (exit #{result.exit_code})"
        end
      end

      # Checks out ref when switching, fast-forwards to the remote ref and returns the files
      # changed between the HEAD before and after. git's own messages go to stderr, so stdout
      # carries only the result: two SHAs, then NUL-separated paths.
      def git_apply(path, ref, remote:, switch:)
        script = <<~SH
          set -eu
          remote_ref="refs/remotes/$2/$3"
          before=$(git -C "$1" rev-parse HEAD)
          if [ "$4" = switch ]; then
            if git -C "$1" show-ref --verify --quiet "refs/heads/$3"; then
              git -C "$1" checkout --quiet "$3" -- >&2
            else
              # --no-track: tracking needs the remote's fetch config to cover the branch, which a
              # single-branch clone's doesn't; Herd compares against the full remote ref anyway.
              git -C "$1" checkout --quiet --no-track -b "$3" "$remote_ref" >&2
            fi
          fi
          git -C "$1" merge --ff-only "$remote_ref" >&2
          after=$(git -C "$1" rev-parse HEAD)
          printf '%s\\n%s\\n' "$before" "$after"
          [ "$before" = "$after" ] || git -C "$1" diff --name-only -z "$before" "$after"
        SH
        output = run("bash -c #{script.shellescape} _ #{shell_path(path)} #{shell_args(remote, ref, switch ? "switch" : "stay")}",
                     pty: false)
        before, after, files = output.split("\n", 3)
        before == after ? [] : files.to_s.split("\0")
      end

      # Full ref names only: a short "origin/main" depends on what refs and config the clone has.
      def git_remote_ref(remote, ref) = "refs/remotes/#{remote}/#{ref}"

      def git_branch!(ref)
        return if ref.to_s.match?(BRANCH)

        raise ArgumentError,
              "git: #{ref.inspect} is not a branch name (tags and SHAs aren't supported)"
      end
    end
  end
end
