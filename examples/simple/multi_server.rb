# frozen_string_literal: true

# Apply a baseline configuration across multiple servers in parallel.
# Uses Playbook to run named stages — pass a stage name as an argument
# to run only that stage.
#
# Run all stages:      bundle exec ruby multi_server.rb
# Run a single stage:  bundle exec ruby multi_server.rb packages

require "herd"

# Define hosts inline or load from CSV:
#   hosts = Herd::Host.from_csv("hosts.csv")  # columns: host,user,port,private_key_path
hosts = [
  # key auth, default port 22
  Herd::Host.new("web-01.example.com", "deploy", private_key_path: "~/.ssh/id_ed25519"),

  # non-standard port
  Herd::Host.new("web-02.example.com", "deploy", private_key_path: "~/.ssh/id_ed25519", port: 2222),

  # password auth
  Herd::Host.new("web-03.example.com", "deploy", password: ENV.fetch("WEB03_PASSWORD")),

  # SSH alias — host/port/proxy_jump resolved from ~/.ssh/config automatically
  Herd::Host.new("web-04-alias", "deploy", private_key_path: "~/.ssh/id_ed25519")
]

runner = Herd::Runner.new(hosts)
playbook = Herd::Playbook.new(runner)

playbook.run(only: ARGV[0]) do
  packages do
    apt_update
    apt_install("htop", "vim", "curl", "unzip")
  end

  shell_defaults do
    ensure_line_in_file("~/.bashrc", "export EDITOR=vim")
    ensure_line_in_file("~/.bashrc", "export HISTSIZE=10000")
  end

  ssh_keys do
    ssh_keygen("~/.ssh/id_ed25519")
    ssh_set_permissions
  end

  crontab_setup do
    add_cron("0 3 * * * certbot renew --quiet")
    add_cron("@reboot cd ~/myapp && bundle exec rackup -p 9292 -D")
  end
end
