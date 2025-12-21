# frozen_string_literal: true

module Langsmith
  # Configuration settings for the Langsmith SDK.
  #
  # @example Configure via block
  #   Langsmith.configure do |config|
  #     config.api_key = "ls_..."
  #     config.tracing_enabled = true
  #     config.project = "my-project"
  #   end
  #
  # @example Configure via environment variables
  #   # LANGSMITH_API_KEY=ls_...
  #   # LANGSMITH_TRACING=true
  #   # LANGSMITH_PROJECT=my-project
  class Configuration
    # @return [String, nil] LangSmith API key (required for tracing)
    attr_accessor :api_key

    # @return [String] LangSmith API endpoint
    attr_accessor :endpoint

    # @return [String] Project name for organizing traces
    attr_accessor :project

    # @return [Boolean] Enable/disable tracing
    attr_accessor :tracing_enabled

    # @return [Integer] Batch size for sending traces
    attr_accessor :batch_size

    # @return [Float] Flush interval in seconds
    attr_accessor :flush_interval

    # @return [Integer] Request timeout in seconds
    attr_accessor :timeout

    # @return [Integer] Maximum retry attempts for failed requests
    attr_accessor :max_retries

    # @return [String, nil] Tenant ID for multi-tenant scenarios
    attr_accessor :tenant_id

    # @return [Integer, nil] Maximum buffered run entries (queue + pending); nil means unlimited
    attr_accessor :max_pending_entries

    def initialize
      @api_key = ENV.fetch("LANGSMITH_API_KEY", nil)
      @endpoint = ENV.fetch("LANGSMITH_ENDPOINT", "https://api.smith.langchain.com")
      @project = ENV.fetch("LANGSMITH_PROJECT", "default")
      @tracing_enabled = env_boolean("LANGSMITH_TRACING", false)
      @batch_size = ENV.fetch("LANGSMITH_BATCH_SIZE", 100).to_i
      @flush_interval = ENV.fetch("LANGSMITH_FLUSH_INTERVAL", 1.0).to_f
      @timeout = ENV.fetch("LANGSMITH_TIMEOUT", 10).to_i
      @max_retries = ENV.fetch("LANGSMITH_MAX_RETRIES", 3).to_i
      @tenant_id = ENV.fetch("LANGSMITH_TENANT_ID", nil)
      @max_pending_entries = ENV.fetch("LANGSMITH_MAX_PENDING_ENTRIES", nil)&.to_i
    end

    # Returns whether tracing is enabled in configuration.
    # Note: This only checks the configuration flag, not whether tracing can actually occur.
    # @return [Boolean]
    # @see #tracing_possible?
    def tracing_enabled?
      @tracing_enabled
    end

    # Returns whether tracing can actually occur (enabled AND has API key).
    # Use this to check if traces will be sent.
    # @return [Boolean]
    def tracing_possible?
      @tracing_enabled && api_key_present?
    end

    # Returns whether an API key is configured.
    # @return [Boolean]
    def api_key_present?
      !@api_key.nil? && !@api_key.empty?
    end

    # Validates the configuration, raising an error if invalid.
    # @raise [ConfigurationError] if tracing is enabled but API key is missing
    # @return [void]
    def validate!
      return unless @tracing_enabled

      raise ConfigurationError, "LANGSMITH_API_KEY is required when tracing is enabled" unless api_key_present?
    end

    private

    def env_boolean(key, default)
      value = ENV.fetch(key, nil)
      return default if value.nil?

      %w[true 1 yes on].include?(value.downcase)
    end
  end
end
