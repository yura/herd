# frozen_string_literal: true

module Herd
  # Runs named stages on every host. A stage is a recipe method called by name, or a
  # block run in the Session, as recipes are:
  #
  #   Herd::Playbook.new(runner).run do
  #     packages do
  #       apt_install %w[htop vim]
  #     end
  #     deploy_app            # a method defined in a recipe module
  #   end
  #
  # Run options (only:, from:, except:) come from ARGV unless given: `ruby play.rb stage`,
  # `--from stage`, `--except stage` (repeatable).
  class Playbook
    USAGE = "usage: [stage] [--from stage] [--except stage ...]"

    def initialize(hosts_or_runner)
      @runner = hosts_or_runner.is_a?(Runner) ? hosts_or_runner : Runner.new(hosts_or_runner)
    end

    # Unknown stage names in only/from/except raise ArgumentError before anything runs.
    def run(**opts, &)
      opts   = self.class.parse_argv(ARGV) if opts.empty?
      only   = opts[:only]&.to_sym
      from   = opts[:from]&.to_sym
      except = Array(opts[:except]).map(&:to_sym)
      @stages = []
      instance_exec(&)

      if @stages.empty?
        puts "playbook: no stages defined — nothing to run"
        return
      end

      check_stage_names!([only, from, *except].compact)
      runnable = select_stages(only, from, except)
      if runnable.empty?
        puts "playbook: all stages skipped by --from/--except — nothing to run"
        return
      end

      @runner.exec do
        runnable.each do |name, args, kwargs, block|
          info("▶ #{name}")
          block ? instance_exec(&block) : send(name, *args, **kwargs)
        end
      end
    end

    # Every call in the run block declares a stage; filtering happens afterwards, so
    # only/from/except are checked against all declared stages.
    def method_missing(name, *args, **kwargs, &block)
      @stages << [name, args, kwargs, block]
    end

    def respond_to_missing?(name, include_private = false)
      super
    end

    def self.parse_argv(argv)
      opts = { only: nil, from: nil, except: [] }
      args = argv.dup
      until args.empty?
        arg = args.shift
        case arg
        when "--from", "--except"
          value = args.shift
          raise ArgumentError, "#{arg} needs a stage name; #{USAGE}" if value.nil? || value.start_with?("-")

          arg == "--from" ? opts[:from] = value.to_sym : opts[:except] << value.to_sym
        when /\A-/
          raise ArgumentError, "unknown option #{arg}; #{USAGE}"
        else
          raise ArgumentError, "only one stage can be given, got #{opts[:only]} and #{arg}; #{USAGE}" if opts[:only]

          opts[:only] = arg.to_sym
        end
      end
      opts[:except] = nil if opts[:except].empty?
      opts
    end

    private

    def check_stage_names!(names)
      declared = @stages.map(&:first)
      unknown  = names - declared
      return if unknown.empty?

      raise ArgumentError, "playbook: no stage named #{unknown.map { "'#{it}'" }.join(", ")}; " \
                           "stages: #{declared.join(", ")}"
    end

    def select_stages(only, from, except)
      stages = only ? @stages.select { |name, *| name == only } : @stages
      if from
        start  = stages.index { |name, *| name == from }
        stages = start ? stages.drop(start) : []
      end
      stages.reject { |name, *| except.include?(name) }
    end
  end
end
