# Herd

Fast host configuration tool.

## TODO

* [x] Run with `sudo`
* [x] Commands with arguments
* [ ] Reading and writing files

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

### Something more complex

```ruby
public_key_path = File.expand_path("~/.ssh/id_ed25519.pub")
my_key = File.read(public_key_path).chomp

result = runner.exec do
  h = hostname
  keys = authorized_keys

  if keys.include?(my_key)
    puts "Key already in authorized_keys on host #{h}"
  else
    add_authorized_key my_key
    puts "Added new key for host #{h}"
  end
end
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
