# frozen_string_literal: true

require_relative "system_helper"

# Logging in by key, against the container's keyonly user, whom sshd lets in by key only.
# The key pair is generated inside the container; only the private key is written to the
# project's tmp/, as a file Net::SSH reads (nothing runs on this machine).
RSpec.describe Herd::Host, "key authentication", :system do
  let(:keys_dir) { Dir.mktmpdir("herd-keys-", File.expand_path("../../tmp", __dir__).tap { FileUtils.mkdir_p(it) }) }

  after { FileUtils.rm_rf(keys_dir) }

  # Generates a key pair in the container; authorize: true adds it to keyonly's
  # authorized_keys. Returns the local path of the private key.
  def container_key(name, authorize:)
    path = File.join(keys_dir, name)
    with_system_session(:nopass) do |s, dir|
      s.run("ssh-keygen -q -t ed25519 -N '' -C #{s.shell_args(name)} -f #{s.shell_path("#{dir}/key")}", pty: false)
      if authorize
        # One sh -c under sudo: in sudo("a && b") only a runs as root.
        authorize_script = 'f=/home/keyonly/.ssh/authorized_keys; cat -- "$1" >> "$f" && chown keyonly:keyonly "$f" && chmod 600 "$f"'
        s.sudo("sh -c #{authorize_script.shellescape} _ #{s.shell_path("#{dir}/key.pub")}")
      end
      File.write(path, s.read_bytes("#{dir}/key"), perm: 0o600)
    end
    path
  end

  def keyonly_host(**auth)
    described_class.new(ENV.fetch("HERD_SYSTEM_HOST", "127.0.0.1"),
                        { user: "keyonly", port: Integer(ENV.fetch("HERD_SYSTEM_PORT")), verify_host_key: :never,
                          user_known_hosts_file: File::NULL, config: false, keys: [], keys_only: true,
                          use_agent: false }.merge(auth))
  end

  after(:all) do
    on_system_host(:nopass) { sudo("rm -f /home/keyonly/.ssh/authorized_keys") } if SystemHost.available?
  end

  it "logs in with an authorized key" do
    key = container_key("authorized", authorize: true)

    expect(keyonly_host(keys: [key]).exec { run("whoami").strip }).to eq("keyonly")
  end

  it "refuses a key that isn't authorized" do
    container_key("authorized", authorize: true)
    stranger = container_key("stranger", authorize: false)

    expect { keyonly_host(keys: [stranger]).exec { run("true") } }
      .to raise_error(Herd::CommandError, /authentication failed/)
  end

  it "refuses the right password where sshd allows keys only" do
    expect { keyonly_host(password: "keyonly-password").exec { run("true") } }
      .to raise_error(Herd::CommandError, /authentication failed/)
  end

  it "still lets password users in: the key-only rule is scoped to keyonly" do
    expect(on_system_host { run("whoami").strip }).to eq("herd")
  end
end
