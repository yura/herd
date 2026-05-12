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
bundle exec ruby multi_server.rb          # all stages
bundle exec ruby multi_server.rb packages # single stage
```

### Credentials

Examples read secrets from environment variables (`ROOT_PASSWORD`, `DEPLOY_PASSWORD`)
or use key-based auth (`private_key_path: "~/.ssh/id_ed25519"`).
