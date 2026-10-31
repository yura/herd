# Herd

Fast host configuration tool.

## Installation

Install from git until the gem is published to RubyGems:

```ruby
# Gemfile
gem "herd-rb", git: "https://github.com/yura/herd.git", branch: "main", require: "herd"
```

```bash
bundle install
```

Once published to RubyGems, install the gem and add to the application's Gemfile by executing:

```bash
bundle add herd-rb
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install herd-rb
```

## Usage

### Single host

```ruby
# password auth
host = Herd::Host.new("tesla.com", user: "elon", password: "T0pS3kr3t")
# or key auth
host = Herd::Host.new("tesla.com", user: "elon")
# or specific key auth
host = Herd::Host.new("tesla.com", user: "elon", keys: ["~/.ssh/custom_key"])

# host configuration can also be taken from the SSH Config
host = Herd::Host.new("tesla-ssh-config")

# run a single command
host.exec("hostname")

# or run a block of commands
host.exec do
  h = hostname
  info("connected to #{h}")
  apt_update
  apt_install("curl", "git")
end
```

### Running commands

`run(command)` returns output and raises `Herd::CommandError` for a nonzero exit code.
Use `run_result` when the exit code is part of the expected result:

```ruby
host.exec do
  result = run_result("grep 'pattern' /var/log/myapp.log")
  result.exit_code  # 0: matches, 1: no matches, 2: an error

  command_success?("test -e /etc/hosts") # just the success boolean
end
```

`run` takes shell as written; file commands take one literal path; `glob` expands a pattern:

```ruby
read_file("~/logs/*.log")   # one file, literally named "*.log"
glob("~/logs/*.log")        # the files that match, as an array
run("ls ~/logs/*.log")      # a shell command — you write the shell
```

Details are in [`Herd::Session`](lib/herd/session.rb) and [`Herd::Commands::Files`](lib/herd/commands/files.rb).

### Multiple hosts in parallel

```ruby
hosts = [
  Herd::Host.new("web-01.example.com"),
  Herd::Host.new("web-02.example.com")
]

runner = Herd::Runner.new(hosts)

# run single command on all hosts in parallel
runner.exec("hostname") # ["alpha001\n", "omega001\n"]

# or run block of commands on all hosts in parallel
runner.exec { hostname + uptime } # ["alpha001\n2000 years\n", "omega001\2500 years\n"]
```

Additional named variables can be passed to the host and are accessible in the configuration block:

```ruby
hosts = [
  Herd::Host.new("web-01.example.com", { user: "elon" }, hostname: "alpha"),
  Herd::Host.new("web-02.example.com", { user: "mask" }, hostname: "omega")
]

runner.exec do |vars|
  set_hostname vars[:hostname]
end
```

List of hosts can be loaded from the CSV file:

```csv
# hosts.csv
host,port,user,password,some_param1,some_param2
alpha.tesla.com,2022,elon,T0pS3kr3t,value1,value2
omega.tesla.com,2023,elon,T0pS3kr3t2,value3,value4
```

```ruby
hosts = Herd::Host.from_csv("hosts.csv")
runner = Herd::Runner.new(hosts)
```

Any Ruby logic works inside the block:

```ruby
my_key = File.read("~/.ssh/id_ed25519.pub").chomp

runner.exec do
  keys = authorized_keys

  if keys.include?(my_key)
    info("key already present")
  else
    add_authorized_key(my_key)
    info("key added")
  end
end
```

Hosts can also be loaded from a CSV file:

```csv
host,port,user,password
alpha.tesla.com,2022,elon,T0pS3kr3t
omega.tesla.com,2023,elon,T0pS3kr3t2
```

```ruby
hosts = Herd::Host.from_csv("hosts.csv")
runner = Herd::Runner.new(hosts)
```

### Playbook

Named stages with optional filtering via CLI arguments:

```ruby
Herd::Playbook.new(hosts).run do
  packages_install
  rbenv_install
  nginx_install
end
```

```bash
bundle exec ruby run.rb                        # all stages
bundle exec ruby run.rb nginx_install          # single stage
bundle exec ruby run.rb --from rbenv_install   # from stage onwards
bundle exec ruby run.rb --except packages_install
```

### Deployer

Pulls the app on each host and runs commit-based one-off operations (migrations, data fixes)
alongside it. Each hook runs once per server; applied hooks are tracked in `~/.herd_deploy/<app_id>/`.
A hook that failed or was interrupted before it was recorded runs again on the next deploy, so its
`actions` should be safe to repeat after a partial run.

```ruby
deployer = Herd::Deployer.new(hosts,
  app_path:  "~/projects/myapp",
  branch:    "main",
  hooks_dir: "deploy/"
)

deployer.pre_pull   { systemctl_stop("puma") }      # after the sync checks, before the merge
deployer.on_failure { |phase, error| systemctl_start("puma") unless error.is_a?(Herd::CommandOutcomeUnknown) }
deployer.check      { run("curl -fsS localhost:3000/up") }

results = deployer.deploy do                        # runs after the after block
  bundle("install")
  systemctl_restart("puma")
end
```

A deploy goes `lock → sync checks → pre_pull → merge → post_pull → hooks → after → check → unlock`.
`deploy` returns a `DeployResult` per host (`status`, `phase`, `hook`, `applied`, `error`) and raises
`Herd::Deployer::DeployError`, carrying all of them, if any host didn't finish:

- `:refused` — stopped before anything changed: the app is dirty or has local commits, or another
  deploy holds the lock;
- `:failed` — a hook, the after block or the health check failed (`check` fails by raising or
  returning `false`), or the host couldn't be reached (`phase: :connect`);
- `:unknown` — a command timed out, its shell was killed or the connection broke
  (`Herd::CommandOutcomeUnknown`); the remote command may still be running, so the lock is left in place.

`app_id` defaults to the app directory's name plus a hash of its absolute path, so two apps with the
same directory name keep separate markers. A tracking dir of an older Herd (`~/.herd_deploy/<name>/`)
is moved to the new one on the first deploy, markers kept.

`on_failure` runs on the host when the deploy fails after `pre_pull` started. Without it, services
`pre_pull` stopped stay stopped (Herd prints a warning). Two deploys of one app on a host can't run at
once; if a deploy died holding the lock, the error says how to remove it.

See [`examples/simple/deploy_app.rb`](examples/simple/deploy_app.rb) and [`examples/README.md`](examples/README.md) for full hook DSL and usage.

### Files

```ruby
runner.exec do
  # upload a local file from ./files/
  file("/etc/sudoers.d/50-deploy", "root", "root", mode: "440")

  write_to_file("/etc/myapp/config.yml", config_content, sudo: true)
  ensure_line_in_file("~/.bashrc", 'export EDITOR=vim')
end
```

### Templates

ERB template from `./files/home/elon/.env.erb`:

```erb
export ALIAS=<%= alias %>
```

```ruby
host = Herd::Host.new("tesla.com", { user: "elon", password: "T0pS3kr3t" }, alias: "alpha001")
Herd::Runner.new([host]).exec do |vars|
  # host.vars contains all named arguments except password:
  # { host: "tesla.com", port: 22, user: "elon", alias: "alpha001" }
  template("/home/elon/.env", "elon", "elon", values: vars)
end
```

### Crontab

```ruby
add_cron("0 3 * * * certbot renew --quiet")
```

See also the [examples/](examples/simple/) directory:
- [`bootstrap.rb`](examples/simple/bootstrap.rb) — first-time server setup
- [`multi_server.rb`](examples/simple/multi_server.rb) — Playbook across multiple servers
- [`deploy_app.rb`](examples/simple/deploy_app.rb) — deploying a Rails app with Deployer

### Logs
Herd logs all commands, outputs and errors into `log/<host>_<port>_<user>/<timestamp>_<pid>_<random>.jsonl`,
one JSON object per line. Log files are created with mode `0600` and never overwrite an earlier one:

```json
{"vars":{"hostname":"alpha001","root_password":"[redacted]","host":"tesla.com","user":"elon","port":22}}
{"timestamp":"2025-11-09 18:10:21.134","caller":"setup","command":"cat ~/.herd-version"}
{"timestamp":"2025-11-09 18:10:21.395","caller":"setup","command":"cat ~/.herd-version","exit_code":0,"time":0.26,"output":"4\r\n"}
```

Values of vars named like `password`, `secret`, `token`, `passphrase` or `private_key`, and of the keys
listed in `sensitive: [...]` in the inventory, are written as `"[redacted]"`. Pass `sensitive: true` to
`run`, `sudo` or `install_file` to keep a command, its output and its error out of the log, exception
messages and `HERD_STREAM`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

### Tests

```bash
bundle exec rspec   # unit specs: RSpec doubles and Net::SSH::Test, nothing is executed
bin/system-spec     # spec/system: real SSH, sudo, bash and files in a throwaway Docker container
```

Unit specs never execute the shell commands Herd builds — not on your machine, not anywhere.
Channel handling (sudo prompt, stderr, exit status, stdin, timeout) is checked against the real
net-ssh `Channel` over a scripted socket (`Net::SSH::Test`); commands are checked with stubs.
`bundle exec rspec` skips `spec/system` and says so.

Everything that needs a real shell — quoting, files, `within`, env, exit codes, users, login by
key and a server that refuses passwords — is in
`spec/system` and runs only inside the container built from `spec/system/Dockerfile`:

- the image contains only the files of `spec/system` (`COPY`); nothing from your machine is mounted;
- no `--privileged`, no Docker socket, no SSH keys or `~/.ssh/config` of yours, no secrets;
- sshd is published on `127.0.0.1` only, on a port Docker picks;
- the container is removed when the run ends, successfully or not.

`spec/system/isolation_spec.rb` checks that boundary: a command run as root in the container can't
change a file created outside it. Without Docker, `bin/system-spec` stops with an error; it never falls
back to your local shell. CI runs both suites.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yura/herd. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Herd project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).
