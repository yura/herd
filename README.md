# Herd

Fast host configuration tool.

## TODO

* [ ] Commands with arguments
* [ ] Reading and writing files
* [ ] Run with `sudo`

## Installation

TODO: Replace `UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG` with your gem name right after releasing it to RubyGems.org. Please do not do it earlier due to security reasons. Alternatively, replace this section with instructions to install your gem from git if you don't plan to release to RubyGems.org.

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install UPDATE_WITH_YOUR_GEM_NAME_IMMEDIATELY_AFTER_RELEASE_TO_RUBYGEMS_ORG
```

## Usage

### Single host interactions

```ruby
# instanciate new host with password
host = Herd::Host.new("tesla.com", "elon", password: "T0pS3kr3t")
# or with key
host = Herd::Host.new("tesla.com", "elon", private_key_path: "~/.ssh/id_ed25519")

# run single command
host.exec("hostname")
# or run block of commands
host.exec do
  hostname + uptime
end
```

### Multiple hosts interactions

```ruby
another_host = Herd::Host.new("tesla.com", "elon", private_key_path: "~/.ssh/id_ed25519")
runner = Runner.new([host, another_host])

# run single command on all hosts in parallel
runner.exec("hostname") # ["alpha001\n", "omega001\n"]

# or run block of commands on all hosts in parallel
runner.exec { hostname + uptime } # ["alpha001\n2000 years\n", "omega001\2500 years\n"]
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Caching and state store

The task graph can persist results between runs to avoid re-executing long steps. By default, caching is disabled; enable it by configuring a state store:

```ruby
Herd.configure do |config|
  config.state_store_adapter = :sqlite
  config.state_store_path = "/var/lib/herd/state.sqlite3"
end

graph = Herd::TaskGraph.new(report: Herd::RunReport.new)
graph.run(host: "alpha", params: { version: "v1" })
```

You can also configure it from the CLI:

```sh
bin/herd --state-store sqlite --state-path /var/lib/herd/state.sqlite3
```

Set `--state-store none` (or `state_store_adapter = nil`) to disable persistence.

Each task can contribute to the cache signature via `signature_params`. For example:

```ruby
graph.task "configure",
           depends_on: ["install"],
           signature_params: ->(ctx, params) { { version: params[:version], config_hash: ctx[:config_hash] } } do |ctx|
  # ...
end
```

At runtime, pass `params:` and optionally `force: true` to `run` to invalidate cached entries for the current host/task signature.

## DSL quick start

Use the DSL helper to assemble a task graph with defaults and signature metadata:

```ruby
recipe = Herd::DSL.define do
  defaults version: "v1"

  task "install" do |_ctx|
    Herd::ExecutionResult.new(value: "install", stdout: "install\n", stderr: "")
  end

  task "configure",
       depends_on: ["install"],
       signature_params: ->(ctx, params) { { version: params[:version], hash: ctx[:config_hash] } } do |ctx|
    Herd::ExecutionResult.new(value: "configure", stdout: "configure\n", stderr: "")
  end
end

context = { config_hash: "abc" }
recipe.run(host: "alpha", context: context)
```

The DSL merges `defaults` with runtime `params` and passes both into the signature builder so cache entries stay consistent.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yura/herd. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Herd project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).
