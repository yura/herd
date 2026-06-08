# frozen_string_literal: true

# Bootstrap a fresh server: create a deploy user, set up SSH access,
# configure hostname, and install essential packages.
#
# Run: bundle exec ruby bootstrap.rb

require "herd"

HOST     = "my-server.example.com"
HOSTNAME = "my-server"
SSH_KEY  = "ssh-ed25519 AAAAC3Nz... your-public-key"

host = Herd::Host.new(HOST, "root", password: ENV.fetch("ROOT_PASSWORD"))

host.exec do
  # Create deploy user
  user_create "deploy"
  change_password("deploy", ENV.fetch("DEPLOY_PASSWORD"))

  # Authorize your SSH key so future connections use key auth
  mkdir_p("/home/deploy/.ssh", "deploy", "deploy", mode: 700)
  write_to_file("/home/deploy/.ssh/authorized_keys", SSH_KEY)
  file_user_and_group("/home/deploy/.ssh/authorized_keys", "deploy", "deploy")
  file_permissions("/home/deploy/.ssh/authorized_keys", 600)

  set_hostname HOSTNAME

  # Essentials
  apt_update
  apt_install %w[curl git vim htop ufw unattended-upgrades]

  info "bootstrap complete — connect as deploy with your SSH key"
end
