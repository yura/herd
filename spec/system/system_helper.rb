# frozen_string_literal: true

require "shellwords"
require "tmpdir"

# spec/system runs Herd against the container bin/system-spec starts (spec/system/Dockerfile).
# Every command a spec makes Herd run executes inside that container, over SSH; nothing is
# executed on the machine running the specs.
module SystemHost
  USERS = {
    herd: "herd-password",     # sudo asks for the password
    nopass: "nopass-password"  # NOPASSWD sudo
  }.freeze

  def self.available?
    ENV.key?("HERD_SYSTEM_PORT")
  end

  # A Host for the container. The container is recreated on every bin/system-spec run,
  # so its host key is never recorded; ~/.ssh/config and keys of the developer aren't used.
  def system_host(user = :herd, **vars)
    Herd::Host.new(
      ENV.fetch("HERD_SYSTEM_HOST", "127.0.0.1"),
      { user: user.to_s, port: Integer(ENV.fetch("HERD_SYSTEM_PORT")), password: USERS.fetch(user),
        verify_host_key: :never, user_known_hosts_file: File::NULL, keys: [], keys_only: true, config: false },
      vars
    )
  end

  # Runs the block in a Session on the container and returns the block's value; the
  # block runs as a Session (instance_exec), as recipes do.
  def on_system_host(user = :herd, &)
    system_host(user).exec(&)
  end

  # Yields a Session on host to the block, which runs in the example (expect works,
  # unlike in host.exec { ... }, where the block runs as the Session).
  def with_host_session(host, &)
    host.exec { yield(self) }
  end

  # Yields the Session and a fresh directory inside the container to the block, which
  # runs in the example (expect works). The directory is removed afterwards.
  def with_system_session(user = :herd, **vars, &)
    system_host(user, **vars).exec do
      session = self
      dir     = session.run("mktemp -d", pty: false).strip
      begin
        yield(session, dir)
      ensure
        session.sudo("rm -rf -- #{dir.shellescape}")
      end
    end
  end
end

RSpec.configure do |config|
  config.include SystemHost, :system

  # Plain `bundle exec rspec` leaves spec/system out and says how to run it.
  unless SystemHost.available?
    config.filter_run_excluding :system
    config.before(:suite) do
      RSpec.configuration.reporter.message("spec/system skipped: run bin/system-spec (needs Docker)")
    end
  end

  # Host#exec writes log/<host>_<port>_<user>/ into the working directory.
  config.around(:each, :system) do |example|
    Dir.mktmpdir("herd-system-") { |dir| Dir.chdir(dir) { example.run } }
  end
end
