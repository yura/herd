# Herd

Fast host configuration tool.

## Installation

Herd is not yet published to RubyGems. To experiment locally:

```bash
git clone https://github.com/yura/herd.git
cd herd
bundle install
```

Executables live in `bin/`, so you can run `bin/herd --help` directly from the repository.

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

### Configuration basics

Configure global defaults via `Herd.configure`. Most setups only need to decide where to keep the state database:

```ruby
Herd.configure do |config|
  config.state_store_adapter = :sqlite # :memory or nil to disable persistence
  config.state_store_path = File.expand_path("tmp/herd-state.sqlite3", __dir__)
end
```

Environment flags mirror the same behaviour:

- `HERD_STATE_DB` — path to SQLite database (enables the adapter automatically).
- `HERD_FORCE=1` — bypass cached results (same as CLI `--force`).
- `HERD_STATE_STORE=memory|sqlite|none` — optional adapter override.
- `HERD_CONCURRENCY=N` — default parallelism for task execution.

The CLI (`bin/herd`) applies these settings before running recipes.

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

## Recipe workflow & CLI

1. **Describe a recipe** (e.g. `deploy.rb`):

    ```ruby
    Herd::DSL.define do
      defaults version: "2025.10"

      task "install" do |ctx|
        Herd::ExecutionResult.new(value: "packages", stdout: "install #{ctx[:host]}\n", stderr: "")
      end

      task "configure",
           depends_on: ["install"],
           signature_params: ->(ctx, params) { { version: params[:version], hash: ctx[:config_hash] } } do |ctx|
        config_path = File.join(ctx[:dir], "#{ctx[:host]}.conf")
        File.write(config_path, "version=#{params[:version]}\nhost=#{ctx[:host]}\n")
        Herd::ExecutionResult.new(value: config_path, stdout: "configure #{ctx[:host]}\n", stderr: "")
      end
    end
    ```

2. **Prepare runtime parameters** (optional `params.yml`):

    ```yaml
    version: 2025.10.1
    dir: tmp/output
    config_hash: abc123
    ```

3. **Run the recipe via CLI**:

    ```bash
    bin/herd \
      --state-store sqlite \
      --state-path tmp/herd-state.sqlite3 \
      run deploy.rb \
      --params-file params.yml \
      --param release=hotfix \
      --host alpha,beta \
      --host gamma \
      --concurrency 4
    ```

    Output example:

    ```text
    Tasks: 2 total | success: 2 | failed: 0 | running: 0 | skipped: 0
    Total runtime: 0.012s
     - install@alpha [success] (0.003s)
     - configure@alpha [success] (0.004s)
     - install@beta [success] (0.002s)
     - configure@beta [success] (0.003s)
     - install@gamma [success] (0.002s)
     - configure@gamma [success] (0.002s)
    Host alpha: success
    Host beta: success
    Host gamma: success
    ```

    Each host inherits `params` and `context`; repeatable `--host` flags or comma-separated lists are supported. Local context receives the resolved `:host`, while `:params` contains merged defaults, files and CLI overrides.

4. **Force rerun** cached steps when needed:

    ```bash
    bin/herd run deploy.rb --force --host alpha
    ```

    The `--force` flag (or `HERD_FORCE=1`) bypasses stored results for the selected hosts/signatures.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/yura/herd. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Herd project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/yura/herd/blob/main/CODE_OF_CONDUCT.md).
