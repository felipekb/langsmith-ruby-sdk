# frozen_string_literal: true

require_relative "langsmith/version"
require_relative "langsmith/errors"
require_relative "langsmith/configuration"
require_relative "langsmith/run"
require_relative "langsmith/context"
require_relative "langsmith/client"
require_relative "langsmith/batch_processor"
require_relative "langsmith/run_tree"
require_relative "langsmith/evaluation"

module Langsmith
  class << self
    # Returns the current configuration.
    # @return [Configuration]
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure Langsmith with a block.
    #
    # @example
    #   Langsmith.configure do |config|
    #     config.api_key = "ls_..."
    #     config.tracing_enabled = true
    #     config.project = "my-project"
    #   end
    #
    # @yield [Configuration] the configuration instance
    # @return [void]
    def configure
      yield(configuration)
      configuration.validate!
    end

    # Reset configuration (useful for testing).
    # @return [void]
    def reset_configuration!
      @configuration = Configuration.new
      @batch_processor = nil
      @client = nil
    end

    # Check if tracing is enabled and possible (has API key).
    # @return [Boolean]
    def tracing_enabled?
      configuration.tracing_possible?
    end

    # Returns the batch processor (lazily initialized).
    # @return [BatchProcessor]
    def batch_processor
      @batch_processor ||= BatchProcessor.new
    end

    # Returns the HTTP client (lazily initialized).
    # @return [Client]
    def client
      @client ||= Client.new
    end

    # Main tracing API - execute a block within a traced context.
    #
    # @param name [String] Name of the operation being traced
    # @param run_type [String] Type of run ("chain", "llm", "tool", etc.)
    # @param inputs [Hash] Input data for the trace
    # @param metadata [Hash] Additional metadata
    # @param tags [Array<String>] Tags for filtering
    # @param extra [Hash] Extra data (e.g., token usage)
    # @param tenant_id [String] Tenant ID for multi-tenant scenarios (overrides global config)
    # @param project [String] Project name for this trace (overrides global config)
    #
    # @example Basic tracing
    #   Langsmith.trace("my_operation", run_type: "chain") do |run|
    #     run.add_metadata(user_id: "123")
    #     result = do_something()
    #     result
    #   end
    #
    # @example Nested traces
    #   Langsmith.trace("parent", run_type: "chain") do
    #     Langsmith.trace("child", run_type: "llm") do
    #       call_llm()
    #     end
    #   end
    #
    # @example Multi-tenant tracing
    #   Langsmith.trace("operation", tenant_id: "tenant-123") do |run|
    #     # This trace goes to tenant-123
    #   end
    #
    # @example Project-specific tracing
    #   Langsmith.trace("operation", project: "my-special-project") do |run|
    #     # This trace goes to my-special-project
    #   end
    #
    # @yield [Run] the run object for adding metadata, events, etc.
    # @return [Object] the return value of the block
    def trace(name, run_type: "chain", inputs: nil, metadata: nil, tags: nil, extra: nil, tenant_id: nil, project: nil,
              &block)
      run_tree = RunTree.new(
        name: name,
        run_type: run_type,
        inputs: inputs,
        metadata: metadata,
        tags: tags,
        extra: extra,
        tenant_id: tenant_id,
        project: project
      )

      run_tree.execute(&block)
    end

    # Flush all pending traces (blocking).
    # Useful before application shutdown or in tests.
    # @return [void]
    def flush
      batch_processor.flush
    end

    # Shutdown the batch processor gracefully.
    # @return [void]
    def shutdown
      batch_processor.shutdown
    end

    # Get the current run from context (if any).
    # @return [Run, nil]
    def current_run
      Context.current_run
    end

    # Check if we're currently inside a trace.
    # @return [Boolean]
    def tracing?
      Context.active?
    end
  end
end

# Load Rails integration if Rails is available
require_relative "langsmith/railtie" if defined?(Rails::Railtie)
