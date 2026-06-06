# frozen_string_literal: true

module Herd
  class Playbook
    def initialize(hosts_or_runner)
      @runner = hosts_or_runner.is_a?(Runner) ? hosts_or_runner : Runner.new(hosts_or_runner)
    end

    def run(**opts, &)
      opts = self.class.parse_argv(ARGV) if opts.empty?
      only   = opts[:only]
      from   = opts[:from]
      except = opts[:except]
      @only = only&.to_sym
      @stages = []
      instance_exec(&)

      stages    = @stages
      skip_from = from&.to_sym
      excluded  = Array(except).map(&:to_sym)

      @runner.exec do
        skipping = !skip_from.nil?
        stages.each do |name, args, kwargs|
          skipping = false if skipping && name.to_sym == skip_from
          next if skipping
          next if excluded.include?(name.to_sym)

          info("▶ #{name}")
          send(name, *args, **kwargs)
        end
      end
    end

    def method_missing(name, *args, **kwargs)
      return if @only && @only != name.to_sym

      @stages << [name, args, kwargs]
    end

    def respond_to_missing?(name, include_private = false)
      super
    end

    def self.parse_argv(argv)
      opts   = { only: nil, from: nil, except: [] }
      i      = 0
      while i < argv.length
        case argv[i]
        when "--from"
          opts[:from] = argv[i + 1]&.to_sym
          i += 2
        when "--except"
          opts[:except] << argv[i + 1].to_sym
          i += 2
        else
          opts[:only] = argv[i].to_sym
          i += 1
        end
      end
      opts[:except] = nil if opts[:except].empty?
      opts
    end
  end
end
