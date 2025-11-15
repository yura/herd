# Herd

Fast host configuration tool.

## TODO

* [x] Run with `sudo`
* [x] Commands with arguments
* [x] Reading and writing files
* [x] Templates (ERB)
* [x] Copy dirs
  * [ ] Compare with Rsync
* [x] Crontab
* [x] Log all commands for all hosts
* [ ] Bug: if file contains some shell variable like `$host` it replaces it with empty value
* [ ] Ask password
* [ ] Does not raise an CommandError if there is an error in a command
* [ ] Check file contains some string, eg `/home/elon/.bashrc` should contain `export EDITOR=vim`
* [ ] ANSI terminal
* [ ] Parallel execution
  * [ ] Add new parameter to "#exec". By default it will be :sequential execution, optionally :parallel
        for parallel execution you can add `:depends_on` for child task and `:label` for parent one.
  * [ ] for sequential execution you can add parallel block in any place
* [ ] Interpret Dockerfile
* [ ] Add user to group

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

List of hosts can be loaded from the CSV file:

```ruby
# hosts.csv
host,port,user,password,some_param1,some_param2
alpha.tesla.com,2022,elon,T0pS3kr3t,value1,value2
omega.tesla.com,2023,elon,T0pS3kr3t2,value3,value4
```

```ruby
hosts = Herd::Host.from_csv("hosts.csv")
runner = Herd::Runner.new(hosts)
...
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

# or even simpler
my_key2 = "ssh-ed25519 ..."

result = runner.exec do
  authorized_keys_contains_exactly([my_key, my_key2])
end
```

### Files and directories

Following example takes file from the `./files/etc/sudoers.d/50-elon`
and copy content to the remote host with required permissions.

```ruby
result = runner.exec do
  file("/etc/sudoers.d/50-elon", "root", "root", 440)

  # or copy dirs
  dir("/home/elon/projects", "elon", "elon")
end
```

### Templates

Following example takes ERB template from the `./templates/home/elon/.env.erb`
and renders using additional `Herd::Host` values and copies content to the remote host
`/home/elon/.env`:

```erb
# File: ./templates/home/elon/.env.erb
export ALIAS=<%= alias %>
```

```ruby
host = Herd::Host.new("tesla.com", "elon", password: "T0pS3kr3t", alias: "alpha001")
runner = Runner.new([host])
runner.exec do |values|
  # values contain named arguments (except password and public_key_path) 
  # from the host constructor:
  # { host: "tesla.com", port: 22, user: "elon", alias: "alpha001" }
  template("/home/elon/.env", "elon", "wheels", values: values)
end
```

### Crontab

```ruby
crontab("* * * * * /some-script.sh")
```

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
