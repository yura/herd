# Herd Examples

## simple/

Standalone scripts for common tasks. Each file runs independently.

| File | Description |
|------|-------------|
| `bootstrap.rb` | First-time server setup: create deploy user, authorize SSH key, set hostname, install packages |
| `deploy_app.rb` | Deploy a Ruby/Rack app: git clone/pull, nginx vhost, systemd service |
| `multi_server.rb` | Run a multi-stage playbook across several servers in parallel; pass a stage name as argument to run a single stage |

### Running

```bash
cd examples/simple
bundle install
bundle exec ruby bootstrap.rb
bundle exec ruby multi_server.rb                       # all stages
bundle exec ruby multi_server.rb packages              # single stage
bundle exec ruby multi_server.rb --from shell_defaults # from stage onwards
bundle exec ruby multi_server.rb --except crontab_setup
```

### Credentials

Examples read secrets from environment variables (`ROOT_PASSWORD`, `DEPLOY_PASSWORD`)
or use key-based auth (`keys: ["~/.ssh/id_ed25519"]`).

---

## Deployer — Hook DSL

Hook files live in a `deploy/` directory and are named `<full-40-char-sha>_description.rb`. Each hook is tied to a specific commit and runs only once that commit is in the history of the deployed `HEAD` — a commit on another branch or a reverted release doesn't count. Pending hooks run parents first (topological order, not commit dates), several hooks of one commit in file name order, before the after block. Applied hooks are recorded in `~/.herd_deploy/<app_id>/` on each server and aren't run again.

A hook is recorded only after its `actions` and `checks` passed. A hook that failed or was interrupted before that (an error halfway through `actions`, `checks` returning `false`, a dropped connection) runs again on the next deploy — write `actions` so that repeating them after a partial run is safe, e.g. `CREATE INDEX IF NOT EXISTS` rather than `CREATE INDEX`.

Hook DSL supports three blocks, all optional:

```ruby
# deploy/c5d96b56ea7e005fb38835751493a1ca43fc5d35_libvips.rb

pre_conditions do
  # return false to skip this hook on this server
  file_exists? "~/projects/myapp/Gemfile"
end

actions do
  apt_update
  apt_install "libvips-dev"
  bundle "install"
  rails("runner", "ActiveStorage::VariantRecord.delete_all")
end

checks do
  # runs after actions to verify the result
  # raise or return false to fail the hook (nil passes); a failed hook isn't recorded
  apt_installed? "libvips-dev"
end
```

To preview pending hooks without applying them:

```ruby
deployer.check_hooks                  # dry_run: true by default: changes nothing, runs only pre_conditions
deployer.check_hooks(dry_run: false)  # apply, without pulling
```
