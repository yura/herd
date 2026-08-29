# frozen_string_literal: true

require "shellwords"

module Herd
  module Commands
    module Ruby
      RBENV_BUNDLE = "~/.rbenv/shims/bundle"
      RBENV_RAILS  = "~/.rbenv/shims/rails"
      RBENV_RAKE   = "~/.rbenv/shims/rake"

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
