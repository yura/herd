# frozen_string_literal: true

# Deploy a simple Ruby/Rack app with nginx + systemd.
# Assumes the server is already bootstrapped (deploy user + SSH key exist).
# The deploy user needs sudo access to write nginx config and manage systemd:
#   echo "deploy ALL=(ALL) NOPASSWD: /usr/bin/systemctl, /usr/bin/tee" | sudo tee /etc/sudoers.d/deploy
#
# Run: bundle exec ruby deploy_app.rb

require "herd"

APP_NAME = "myapp"
APP_PATH = "/home/deploy/#{APP_NAME}"
DOMAIN   = "my-server.example.com"

host = Herd::Host.new(DOMAIN, "deploy", private_key_path: "~/.ssh/id_ed25519")

host.exec do
  # Clone or update app
  if file_exists?(APP_PATH)
    within(APP_PATH) { run("git pull --ff-only") }
    info("#{APP_NAME} updated")
  else
    run("git clone https://github.com/example/#{APP_NAME}.git #{APP_PATH}")
    info("#{APP_NAME} cloned")
  end

  # nginx vhost
  nginx_conf = <<~CONF
    server {
      listen 80;
      server_name #{DOMAIN};

      location / {
        proxy_pass http://127.0.0.1:9292;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
      }
    }
  CONF

  expect_file_content_equals("/etc/nginx/conf.d/#{APP_NAME}.conf", nginx_conf)
  sudo("nginx -t")
  systemctl_reload("nginx")

  # systemd service
  service = <<~UNIT
    [Unit]
    Description=#{APP_NAME}
    After=network.target

    [Service]
    User=deploy
    WorkingDirectory=#{APP_PATH}
    ExecStart=/usr/bin/env bundle exec rackup -p 9292
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
  UNIT

  expect_file_content_equals("/etc/systemd/system/#{APP_NAME}.service", service)
  systemctl_daemon_reload
  systemctl_enable(APP_NAME)
  systemctl_restart(APP_NAME)

  info("#{APP_NAME} deployed and running")
end
