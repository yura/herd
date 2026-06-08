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
or use key-based auth (`private_key_path: "~/.ssh/id_ed25519"`).

---

## Deployer — Hook DSL

Hook files live in a `deploy/` directory and are named `<full-40-char-sha>_description.rb`. Each hook is tied to a specific commit — the deployer checks whether that commit exists in the app's git log, skips already-applied hooks, and runs the rest in commit-timestamp order before the after-block. Applied hooks are tracked in `~/.herd_deploy/<app>/` on each server, so they run exactly once.

Hook DSL supports three blocks, all optional:

```ruby
# deploy/c5d96b56ea7e005fb38835751493a1ca43fc5d35_libvips.rb

pre_conditions do
  # return false to skip this hook on this server
  file_exists?("~/projects/myapp/Gemfile")
end

actions do
  apt_update
  apt_install("libvips-dev")
  bundle("install")
  rails("runner", "ActiveStorage::VariantRecord.delete_all")
end

checks do
  # runs after actions to verify the result
  # raise or return false to mark hook as failed
  apt_installed?("libvips-dev")
end
```

To preview pending hooks without applying them:

```ruby
deployer.check_hooks                  # dry_run: true by default
deployer.check_hooks(dry_run: false)  # apply
```
