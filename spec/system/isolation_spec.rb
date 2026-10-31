# frozen_string_literal: true

require_relative "system_helper"

# The boundary of spec/system: commands run in the container can't reach the files of
# the machine running the specs. bin/system-spec mounts nothing into the container.
#
# Control files go to the project's tmp/ (gitignored): a mounted project is the likeliest
# leak, and the project usually sits under the developer's home, so this covers both.
RSpec.describe "spec/system isolation", :system do
  let(:project_tmp) { File.expand_path("../../tmp", __dir__).tap { FileUtils.mkdir_p(it) } }

  around do |example|
    @outside = Dir.mktmpdir("herd-isolation-", project_tmp)
    example.run
  ensure
    FileUtils.rm_rf(@outside)
  end

  it "can't change a file created outside the container, even as root" do
    control = File.join(@outside, "control")
    File.write(control, "untouched\n")

    with_system_session do |s, _|
      script = 'mkdir -p -- "$1" && printf changed > "$2"'
      s.sudo("sh -c #{script.shellescape} _ #{s.shell_path(@outside)} #{s.shell_path(control)}")
      s.sudo("rm -rf -- #{s.shell_path(@outside)}")
    end

    expect(File.read(control)).to eq("untouched\n")
  end

  # A unique file rather than a known path: /root or /home/... may exist in the container
  # too, and a matching path says nothing about shared files.
  it "sees neither a file in the project nor a Docker socket" do
    control = File.join(@outside, "visible-#{SecureRandom.hex(8)}")
    File.write(control, "outside\n")

    # As root (nopass has NOPASSWD sudo), so file permissions can't hide it.
    with_system_session(:nopass) do |s, _|
      expect(s.command_success?("#{s.sudo_prefix} test -e #{s.shell_path(control)}")).to be(false)
      expect(s.command_success?("#{s.sudo_prefix} true")).to be(true)
      expect(s.command_success?("test -S /var/run/docker.sock")).to be(false)
    end
  end
end
