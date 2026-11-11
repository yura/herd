# frozen_string_literal: true

require_relative "system_helper"

# apt_add_repo with real gpg and curl. Keys are generated in the container and fetched
# from file:// URLs; apt_update is stubbed, the container has no network to update from.
RSpec.describe Herd::Commands::Apt, :system do
  # Generates an Ed25519 key with the given user ID in its own homedir; exports it to
  # dir/name.gpg (binary) and dir/name.asc (armored). Returns the fingerprint.
  def generate_key(s, dir, name, uid: "#{name} <#{name}@example.com>")
    home = "#{dir}/gnupg-#{name}"
    s.run("mkdir -m 700 -- #{s.shell_path(home)}")
    gpg = "gpg --homedir #{s.shell_path(home)} --batch"
    s.run("#{gpg} --passphrase '' --quick-gen-key #{s.shell_args(uid)} ed25519 sign never", pty: false)
    s.run("#{gpg} --export -o #{s.shell_path("#{dir}/#{name}.gpg")}", pty: false)
    s.run("#{gpg} --armor --export -o #{s.shell_path("#{dir}/#{name}.asc")}", pty: false)
    s.run("#{gpg} --with-colons --list-keys", pty: false)[/^fpr:+(\h+):/, 1]
  end

  def stat(s, path) = s.run("stat -c '%U:%G %a' -- #{s.shell_path(path)}", pty: false).strip

  def add_repo(s, dir, key, **)
    allow(s).to receive(:apt_update)
    s.apt_add_repo("#{dir}/example.list", "deb [signed-by=#{dir}/keyring.gpg] https://example.com/apt stable main",
                   keyring_path: "#{dir}/keyring.gpg", keyring_url: "file://#{dir}/#{key}", **)
  end

  it "installs a key with the expected fingerprint, root-owned and readable by apt, and the sources entry" do
    with_system_session do |s, dir|
      fpr = generate_key(s, dir, "vendor")
      add_repo(s, dir, "vendor.gpg", fingerprint: fpr)

      expect(s.read_bytes("#{dir}/keyring.gpg", sudo: true)).to eq(s.read_bytes("#{dir}/vendor.gpg"))
      expect(stat(s, "#{dir}/keyring.gpg")).to eq("root:root 644")
      expect(s.read_file("#{dir}/example.list")).to include("signed-by=#{dir}/keyring.gpg")
      expect(s).to have_received(:apt_update)
    end
  end

  it "rejects a key whose user ID merely contains the expected fingerprint" do
    with_system_session do |s, dir|
      fpr = generate_key(s, dir, "vendor")
      generate_key(s, dir, "evil", uid: "fpr:::::::::#{fpr}: <evil@example.com>")

      expect { add_repo(s, dir, "evil.gpg", fingerprint: fpr) }.to raise_error(Herd::CommandError, /expected exactly/)
      expect(s.file_exists?("#{dir}/keyring.gpg")).to be(false)
      expect(s.file_exists?("#{dir}/example.list")).to be(false)
    end
  end

  it "replaces a keyring holding an extra key with exactly the expected one" do
    with_system_session do |s, dir|
      fpr = generate_key(s, dir, "vendor")
      generate_key(s, dir, "extra")
      s.run("cat -- #{s.shell_path("#{dir}/vendor.gpg")} #{s.shell_path("#{dir}/extra.gpg")} > " \
            "#{s.shell_path("#{dir}/keyring.gpg")}")

      add_repo(s, dir, "vendor.gpg", fingerprint: fpr)

      expect(s.read_bytes("#{dir}/keyring.gpg", sudo: true)).to eq(s.read_bytes("#{dir}/vendor.gpg"))
    end
  end

  it "keeps a working keyring when the downloaded key doesn't match" do
    with_system_session do |s, dir|
      fpr = generate_key(s, dir, "vendor")
      generate_key(s, dir, "other")
      add_repo(s, dir, "vendor.gpg", fingerprint: fpr)
      s.sudo("chmod 600 -- #{s.shell_path("#{dir}/keyring.gpg")}") # makes it look broken: mode is wrong

      # Content is right, so only the mode is fixed; the bogus URL would fail if fetched.
      add_repo(s, dir, "missing.gpg", fingerprint: fpr)
      expect(stat(s, "#{dir}/keyring.gpg")).to eq("root:root 644")

      expect { add_repo(s, dir, "other.gpg", fingerprint: generate_key(s, dir, "third")) }
        .to raise_error(Herd::CommandError, /expected exactly/)
      expect(s.read_bytes("#{dir}/keyring.gpg", sudo: true)).to eq(s.read_bytes("#{dir}/vendor.gpg"))
    end
  end

  it "re-fetches an empty keyring file" do
    with_system_session do |s, dir|
      fpr = generate_key(s, dir, "vendor")
      s.run("touch -- #{s.shell_path("#{dir}/keyring.gpg")}")

      add_repo(s, dir, "vendor.gpg", fingerprint: fpr)

      expect(s.read_bytes("#{dir}/keyring.gpg", sudo: true)).to eq(s.read_bytes("#{dir}/vendor.gpg"))
    end
  end

  it "dearmors an ASCII-armored key into a binary keyring" do
    with_system_session do |s, dir|
      fpr = generate_key(s, dir, "vendor")

      add_repo(s, dir, "vendor.asc", fingerprint: fpr, dearmor: true)

      expect(s.read_bytes("#{dir}/keyring.gpg", sudo: true)).to eq(s.read_bytes("#{dir}/vendor.gpg"))
    end
  end

  it "refuses a download that isn't a key, even without a fingerprint" do
    with_system_session do |s, dir|
      s.run("printf '<html>not found</html>' > #{s.shell_path("#{dir}/page.gpg")}")

      expect { add_repo(s, dir, "page.gpg") }.to raise_error(Herd::CommandError, /not an OpenPGP key/)
      expect(s.file_exists?("#{dir}/keyring.gpg")).to be(false)
    end
  end
end
