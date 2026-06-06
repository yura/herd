# frozen_string_literal: true

module Herd
  class Playbook
    def initialize(runner)
      @runner = runner
    end

    def run(only: nil, &block)
      @only = only&.to_sym
      @stages = []
      instance_exec(&block)

      stages = @stages
      @runner.exec do
        stages.each do |name, args, kwargs|
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
  end
end
