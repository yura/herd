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

Handles commit-based one-off operations (migrations, data fixes) alongside regular deploys. Each hook runs exactly once per server, tracked in `~/.herd_deploy/<app>/`.

```ruby
deployer = Herd::Deployer.new(hosts,
  app_path:  "~/projects/myapp",
  branch:    "main",
  hooks_dir: "deploy/"
)

deployer.deploy do
  bundle("install")
  systemctl_restart("puma")
end
```

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
Herd logs all commands, outputs and errors into the `log/<host>_<port>_<user>/<timestamp>.json` files:

```json
{
{"vars":{"alias":"alpha001","port":22,"host":"tesla.com","user":"elon"}},
{"timestamp":"2025-11-09 18:10:21.134","command":"test -a /home/elon/.herd-version; echo $?"},
{"timestamp":"2025-11-09 18:10:21.395","command":"test -a /home/elon/.herd-version; echo $?","output":"4\r\n","time":0.261358},
{"timestamp":"2025-11-09 18:10:22.013","command":"cat /home/home/.herd-version"},
{"timestamp":"2025-11-09 18:10:22.314","command":"cat /home/home/.herd-version","output":"4\r\n","time":0.301}
}
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yura/herd. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Herd project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).
