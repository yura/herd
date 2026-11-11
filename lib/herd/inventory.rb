# frozen_string_literal: true

module Herd
  # Loads _common.rb, then every non-_ file; they call common(**config) and register_server(name, **config).
  class Inventory
    SSH_KEYS = %i[host user port password identity_file].freeze

    attr_reader :dir, :servers

    def self.load(dir)
      new(dir).tap(&:load)
    end

    def initialize(dir)
      @dir     = File.expand_path(dir)
      @servers = {}
      @common  = {}
    end

    def load
      common_file = File.join(dir, "_common.rb")
      files = Dir[File.join(dir, "*.rb")].reject { |f| File.basename(f).start_with?("_") }.sort
      files.unshift(common_file) if File.exist?(common_file)

      files.each do |file|
        @current_file = file
        instance_eval(File.read(file), file)
      end
      self
    ensure
      @current_file = nil
    end

    # With no arguments returns the shared config, so server files can splat it: **common.
    def common(**config)
      config.any? ? @common.merge!(config) : @common
    end

    def register_server(name, **config)
      @servers[name] = config.merge(config_file: @current_file)
    end

    # user: overrides the server's own; password: names the config key holding
    # the SSH password (e.g. :root_password). Everything else lands in host.vars.
    def hosts(*names, user: nil, password: :password)
      names.map do |name|
        config = @servers.fetch(name) { raise ArgumentError, "unknown server: #{name}" }
        Herd::Host.new(config.fetch(:host), ssh_options(config, user, password), host_vars(name, config))
      end
    end

    private

    def ssh_options(config, user, password)
      options = { user: user || config[:user], port: config[:port], password: config[password] }
      options[:keys] = [config[:identity_file]] if config[:identity_file]
      options.compact
    end

    def host_vars(name, config)
      config.except(*SSH_KEYS).merge(hostname: name)
    end
  end
end
