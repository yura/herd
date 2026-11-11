# frozen_string_literal: true

require_relative "system_helper"

RSpec.describe Herd::Commands::Crontab, :system do
  it "adds an entry to a user who has no crontab yet, once, without the shell expanding it" do
    with_system_session(:nopass) do |s, _|
      s.run("crontab -r 2>/dev/null; true", pty: false)
      entry = %(0 3 * * * echo "$HOME" `date +%F` $(id -u) > /tmp/x)

      expect(s.add_cron(entry)).to be(true)
      expect(s.add_cron(entry)).to be(false)
      expect(s.add_cron("5 4 * * * true")).to be(true)

      expect(s.run("crontab -l", pty: false)).to eq("#{entry}\n5 4 * * * true\n")
    ensure
      s.run("crontab -r 2>/dev/null; true", pty: false)
    end
  end

  it "replaces the crontab with crontab()" do
    with_system_session(:nopass) do |s, _|
      s.add_cron("1 1 * * * old")
      s.crontab("2 2 * * * new\n3 3 * * * newer")

      expect(s.run("crontab -l", pty: false)).to eq("2 2 * * * new\n3 3 * * * newer\n")
    ensure
      s.run("crontab -r 2>/dev/null; true", pty: false)
    end
  end
end

RSpec.describe Herd::Commands::System, :system do
  it "points 127.0.1.1 in /etc/hosts at the new hostname" do
    with_system_session(:nopass) do |s, _|
      original = s.read_bytes("/etc/hosts", sudo: true)
      allow(s).to receive(:sudo).and_call_original
      allow(s).to receive(:sudo).with(/\Ahostnamectl /) # no systemd in the container
      s.ensure_line_in_file("/etc/hosts", "127.0.1.1\told-name", sudo: true)

      s.set_hostname("web-1.example.com")

      expect(s.read_file("/etc/hosts", sudo: true).lines(chomp: true)).to include("127.0.1.1\tweb-1.example.com")
      expect { s.set_hostname("x; touch /tmp/pwned") }.to raise_error(ArgumentError)
    ensure
      s.install_file("/etc/hosts", original, sudo: true) if original
    end
  end
end
