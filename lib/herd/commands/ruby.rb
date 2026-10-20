# frozen_string_literal: true

require "shellwords"

module Herd
  module Commands
    module Ruby
      RBENV_ROOT   = "~/.rbenv"
      RBENV        = "~/.rbenv/bin/rbenv"
      RBENV_BUNDLE = "~/.rbenv/shims/bundle"
      RBENV_RAILS  = "~/.rbenv/shims/rails"
      RBENV_RAKE   = "~/.rbenv/shims/rake"

      # What ruby-build needs to compile Ruby — Ubuntu/Debian package names.
      RUBY_BUILD_APT_DEPS = %w[git build-essential autoconf libssl-dev libyaml-dev zlib1g-dev libffi-dev libgmp-dev
                               rustc].freeze

      # rbenv + ruby-build in ~/.rbenv, pulled to master every run so new Ruby versions show up.
      # build_deps: false skips the apt packages (non-Debian hosts, or already handled).
      def rbenv_install(build_deps: true)
        if build_deps && !file_exists?("#{RBENV_ROOT}/.git")
          apt_update
          apt_install(RUBY_BUILD_APT_DEPS)
        end

        git_repo(RBENV_ROOT, "https://github.com/rbenv/rbenv.git", ref: "master")
        git_repo("#{RBENV_ROOT}/plugins/ruby-build", "https://github.com/rbenv/ruby-build.git", ref: "master")
        run("mkdir -p #{RBENV_ROOT}/cache")

        # Full path in init: shell detection is unreliable in a non-interactive SSH session.
        ensure_line_in_file("~/.bashrc", 'export PATH="$HOME/.rbenv/bin:$PATH"')
        ensure_line_in_file("~/.bashrc", 'eval "$($HOME/.rbenv/bin/rbenv init - bash)"')
      end

      # Returns true if the version had to be built.
      def rbenv_install_ruby(version)
        if run("#{RBENV} versions --bare").split.include?(version)
          info("ruby #{version} already installed, skipping")
          return false
        end

        run("#{RBENV} install #{version}")
        info("ruby #{version} installed")
        true
      end

      # Returns true if the global version changed.
      def rbenv_global(version)
        if run("#{RBENV} global").strip == version
          info("ruby #{version} already global, skipping")
          return false
        end

        run("#{RBENV} global #{version}")
        info("ruby #{version} set as global")
        true
      end

      def bundle(*args)
        run("#{RBENV_BUNDLE} #{args.join(" ")}")
      end

      def rails(*args, env: "production")
        run("RAILS_ENV=#{env} #{RBENV_RAILS} #{args.join(" ")}")
      end

      def rails_runner(code, env: "production", warnings: false)
        redirect = warnings ? "" : " 2>/dev/null"
        run("RUBYOPT='-E UTF-8:UTF-8' RAILS_ENV=#{env} #{RBENV_RAILS} runner #{code.shellescape}#{redirect}")
      end

      def rake(*args, env: "production")
        run("RAILS_ENV=#{env} #{RBENV_RAKE} #{args.join(" ")}")
      end
    end
  end
end
