# frozen_string_literal: true

module Herd
  class Playbook
    def initialize(runner)
      @runner = runner
    end

    def run(only: nil, &block)
      @only = only&.to_sym
      instance_exec(&block)
    end

    def method_missing(name, *args)
      return if @only && @only != name.to_sym

      @runner.exec { send(name, *args) }
    end

    def respond_to_missing?(name, include_private = false)
      super
    end
  end
end
