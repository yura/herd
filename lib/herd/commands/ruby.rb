# frozen_string_literal: true

module Herd
  module Commands
    module Ruby
      RBENV_BUNDLE = "~/.rbenv/shims/bundle"
      RBENV_RAILS  = "~/.rbenv/shims/rails"
      RBENV_RAKE   = "~/.rbenv/shims/rake"

      def bundle(*args)
        run("#{RBENV_BUNDLE} #{args.join(' ')}")
      end

      def rails(*args, env: "production")
        run("RAILS_ENV=#{env} #{RBENV_RAILS} #{args.join(' ')}")
      end

      def rake(*args, env: "production")
        run("RAILS_ENV=#{env} #{RBENV_RAKE} #{args.join(' ')}")
      end
    end
  end
end
