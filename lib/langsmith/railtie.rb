# frozen_string_literal: true

module Langsmith
  # Rails integration for automatic configuration and lifecycle management.
  #
  # When Rails is detected, this Railtie will:
  # - Automatically configure Langsmith from Rails credentials or environment
  # - Register shutdown hooks to flush traces before the application exits
  # - Provide a generator for creating an initializer
  #
  # @example Using Rails credentials (config/credentials.yml.enc)
  #   langsmith:
  #     api_key: ls_...
  #     project: my-rails-app
  #
  # @example Using environment variables
  #   LANGSMITH_API_KEY=ls_...
  #   LANGSMITH_PROJECT=my-rails-app
  #   LANGSMITH_TRACING=true
  #
  class Railtie < ::Rails::Railtie
    config.langsmith = ActiveSupport::OrderedOptions.new

    # Default configuration values
    config.langsmith.auto_configure = true
    config.langsmith.tracing_enabled = nil # nil means defer to env var

    initializer "langsmith.configure" do |app|
      next unless app.config.langsmith.auto_configure

      configure_from_rails(app)
    end

    config.after_initialize do
      # Log configuration status in development
      if Rails.env.development? && Langsmith.tracing_enabled?
        Rails.logger.info "[Langsmith] Tracing enabled for project: #{Langsmith.configuration.project}"
      end
    end

    # Ensure traces are flushed before the application exits
    config.before_configuration do
      at_exit do
        Langsmith.shutdown if Langsmith.tracing_enabled?
      rescue StandardError => e
        Rails.logger.error "[Langsmith] Error during shutdown: #{e.message}" if defined?(Rails.logger)
      end
    end

    private

    def configure_from_rails(app) # rubocop:disable Metrics/AbcSize
      Langsmith.configure do |config|
        # Try Rails credentials first, fall back to environment variables
        credentials = app.credentials.langsmith || {}

        config.api_key = credentials[:api_key] || ENV.fetch("LANGSMITH_API_KEY", nil)
        config.endpoint = credentials[:endpoint] || ENV.fetch("LANGSMITH_ENDPOINT", "https://api.smith.langchain.com")
        config.project = credentials[:project] || ENV.fetch("LANGSMITH_PROJECT",
                                                            Rails.application.class.module_parent_name.underscore)
        config.tenant_id = credentials[:tenant_id] || ENV.fetch("LANGSMITH_TENANT_ID", nil)

        # Tracing can be set via Rails config, credentials, or environment
        config.tracing_enabled = resolve_tracing_enabled(app, credentials)

        # Optional settings from credentials
        config.batch_size = credentials[:batch_size] if credentials[:batch_size]
        config.flush_interval = credentials[:flush_interval] if credentials[:flush_interval]
        config.timeout = credentials[:timeout] if credentials[:timeout]
      end
    rescue Langsmith::ConfigurationError => e
      Rails.logger.warn "[Langsmith] Configuration error: #{e.message}" if defined?(Rails.logger)
    end

    def resolve_tracing_enabled(app, credentials)
      # Priority: Rails config > credentials > environment variable
      return app.config.langsmith.tracing_enabled unless app.config.langsmith.tracing_enabled.nil?
      return credentials[:tracing_enabled] unless credentials[:tracing_enabled].nil?

      env_value = ENV.fetch("LANGSMITH_TRACING", nil)
      return false if env_value.nil?

      %w[true 1 yes on].include?(env_value.downcase)
    end
  end
end
