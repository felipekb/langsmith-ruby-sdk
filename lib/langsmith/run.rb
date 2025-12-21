# frozen_string_literal: true

require "securerandom"
require "time"
require "json"

module Langsmith
  # Represents a single trace run/span in LangSmith.
  # All run types (chain, llm, tool, etc.) use this same class with different run_type values.
  #
  # @example Creating a run
  #   run = Langsmith::Run.new(name: "my_operation", run_type: "chain")
  #   run.add_metadata(user_id: "123")
  #   run.finish(outputs: { result: "success" })
  class Run
    # Valid run types supported by LangSmith
    VALID_RUN_TYPES = %w[chain llm tool retriever prompt parser].freeze

    # @return [String] unique identifier for this run
    attr_reader :id

    # @return [String] name of the operation
    attr_reader :name

    # @return [String] type of run (chain, llm, tool, etc.)
    attr_reader :run_type

    # @return [String, nil] parent run ID for nested traces
    attr_reader :parent_run_id

    # @return [String] project/session name
    attr_reader :session_name

    # @return [Time] when the run started
    attr_reader :start_time

    # @return [String, nil] tenant ID for multi-tenant scenarios
    attr_reader :tenant_id

    # @return [String] trace ID (root run's ID)
    attr_reader :trace_id

    # @return [String] dotted order for trace tree ordering
    attr_reader :dotted_order

    # @return [Hash] input data
    attr_accessor :inputs

    # @return [Hash, nil] output data
    attr_accessor :outputs

    # @return [String, nil] error message if run failed
    attr_accessor :error

    # @return [Time, nil] when the run ended
    attr_accessor :end_time

    # @return [Hash] additional metadata
    attr_accessor :metadata

    # @return [Hash] extra data (e.g., token usage)
    attr_accessor :extra

    # @return [Array<Hash>] events that occurred during the run
    attr_accessor :events

    # @return [Array<String>] tags for filtering
    attr_accessor :tags

    # Creates a new Run instance.
    #
    # @param name [String] name of the operation
    # @param run_type [String] type of run ("chain", "llm", "tool", etc.)
    # @param inputs [Hash, nil] input data
    # @param parent_run_id [String, nil] parent run ID for nested traces
    # @param session_name [String, nil] project/session name
    # @param metadata [Hash, nil] additional metadata
    # @param tags [Array<String>, nil] tags for filtering
    # @param extra [Hash, nil] extra data
    # @param id [String, nil] custom ID (auto-generated if not provided)
    # @param tenant_id [String, nil] tenant ID for multi-tenant scenarios
    # @param trace_id [String, nil] trace ID (defaults to own ID for root runs)
    # @param parent_dotted_order [String, nil] parent's dotted order for tree ordering
    #
    # @raise [ArgumentError] if run_type is invalid
    def initialize(
      name:,
      run_type: "chain",
      inputs: nil,
      parent_run_id: nil,
      session_name: nil,
      metadata: nil,
      tags: nil,
      extra: nil,
      id: nil,
      tenant_id: nil,
      trace_id: nil,
      parent_dotted_order: nil
    )
      @id = id || SecureRandom.uuid
      @name = name
      @run_type = validate_run_type(run_type)
      @inputs = inputs || {}
      @outputs = nil
      @error = nil
      @parent_run_id = parent_run_id
      @session_name = session_name || Langsmith.configuration.project
      @tenant_id = tenant_id || Langsmith.configuration.tenant_id
      # trace_id is the root run's ID; for root runs it equals the run's own ID
      @trace_id = trace_id || @id
      @start_time = Time.now.utc
      @end_time = nil
      @metadata = metadata || {}
      @tags = tags || []
      @extra = extra || {}
      @events = []
      # dotted_order is used for ordering runs in the trace tree
      @dotted_order = build_dotted_order(parent_dotted_order)
    end

    # Marks the run as finished.
    #
    # @param outputs [Hash, nil] output data
    # @param error [Exception, String, nil] error if the run failed
    # @return [self]
    def finish(outputs: nil, error: nil)
      @end_time = Time.now.utc
      @outputs = outputs if outputs
      @error = format_error(error) if error
      self
    end

    # Adds metadata to the run.
    #
    # @param new_metadata [Hash] metadata to merge
    # @return [nil] returns nil to prevent circular reference when used as last line
    def add_metadata(new_metadata)
      @metadata.merge!(new_metadata)
      nil
    end

    # Adds tags to the run.
    #
    # @param new_tags [Array<String>] tags to add
    # @return [nil] returns nil to prevent circular reference when used as last line
    def add_tags(*new_tags)
      @tags.concat(new_tags.flatten)
      nil
    end

    # Adds an event to the run.
    #
    # @param name [String] event name
    # @param time [Time, nil] event time (defaults to now)
    # @param kwargs [Hash] additional event data
    # @return [nil] returns nil to prevent circular reference when used as last line
    def add_event(name:, time: nil, **kwargs)
      @events << {
        name: name,
        time: (time || Time.now.utc).iso8601(3),
        **kwargs
      }
      nil
    end

    # Sets token usage for LLM runs.
    # Follows the Python SDK pattern: tokens are stored in extra.metadata.usage_metadata
    # with keys: input_tokens, output_tokens, total_tokens
    #
    # @param input_tokens [Integer, nil] number of input/prompt tokens
    # @param output_tokens [Integer, nil] number of output/completion tokens
    # @param total_tokens [Integer, nil] total tokens (calculated if not provided)
    # @return [nil] returns nil to prevent circular reference when used as last line
    def set_token_usage(input_tokens: nil, output_tokens: nil, total_tokens: nil)
      calculated_total = total_tokens || ((input_tokens || 0) + (output_tokens || 0))

      @extra[:metadata] ||= {}
      @extra[:metadata][:usage_metadata] = {
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: calculated_total
      }.compact

      nil # Return nil to prevent circular reference if used as last line of trace block
    end

    # Sets LLM model metadata.
    # The model name should be stored in extra.metadata for LangSmith to display it.
    #
    # @param model [String] the model name/identifier
    # @param provider [String, nil] the model provider (e.g., "openai", "anthropic")
    # @return [nil] returns nil to prevent circular reference when used as last line
    def set_model(model:, provider: nil)
      @extra[:metadata] ||= {}
      @extra[:metadata][:ls_model_name] = model
      @extra[:metadata][:ls_provider] = provider if provider
      nil
    end

    # Sets streaming metrics for LLM runs.
    # Useful for tracking performance of streaming responses.
    #
    # @param time_to_first_token [Float, nil] time in seconds until first token received
    # @param chunk_count [Integer, nil] total number of chunks received
    # @param tokens_per_second [Float, nil] throughput in tokens per second
    # @return [nil] returns nil to prevent circular reference when used as last line
    def set_streaming_metrics(time_to_first_token: nil, chunk_count: nil, tokens_per_second: nil)
      @extra[:metadata] ||= {}
      @extra[:metadata][:streaming_metrics] = {
        time_to_first_token_s: time_to_first_token,
        chunk_count: chunk_count,
        tokens_per_second: tokens_per_second
      }.compact

      nil
    end

    # Returns whether the run has finished.
    # @return [Boolean]
    def finished?
      !end_time.nil?
    end

    # Returns the duration in milliseconds.
    # @return [Float, nil] duration in ms, or nil if not finished
    def duration_ms
      return nil unless end_time

      ((end_time - start_time) * 1000).round(2)
    end

    # Convert to hash for JSON serialization to LangSmith API (full run for POST).
    # Token usage is stored in extra.metadata.usage_metadata following Python SDK pattern.
    #
    # @return [Hash]
    def to_h
      {
        id:,
        name:,
        run_type:,
        inputs:,
        outputs:,
        error:,
        parent_run_id:,
        trace_id:,
        dotted_order:,
        session_name:,
        start_time: start_time.iso8601(3),
        end_time: end_time&.iso8601(3),
        extra: extra.empty? ? nil : extra,
        events: events.empty? ? nil : events,
        tags: tags.empty? ? nil : tags,
        serialized: { name: },
        **(metadata.empty? ? {} : { metadata: })
      }.compact
    end

    # Convert to hash for PATCH requests (only fields that change on completion).
    # Note: parent_run_id is required for LangSmith to validate dotted_order correctly.
    # Token usage is included in extra.metadata.usage_metadata.
    # Metadata and tags are included as they may be added during execution.
    #
    # @return [Hash]
    def to_update_h
      {
        id:,
        trace_id:,
        parent_run_id:,
        dotted_order:,
        end_time: end_time&.iso8601(3),
        outputs:,
        error:,
        events: events.empty? ? nil : events,
        extra: extra.empty? ? nil : extra,
        tags: tags.empty? ? nil : tags,
        **(metadata.empty? ? {} : { metadata: })
      }.compact
    end

    # Convert to JSON string.
    #
    # @return [String]
    def to_json(*args)
      to_h.to_json(*args)
    end

    private

    def validate_run_type(run_type)
      return run_type if VALID_RUN_TYPES.include?(run_type)

      raise ArgumentError, "Invalid run_type '#{run_type}'. Must be one of: #{VALID_RUN_TYPES.join(", ")}"
    end

    def format_error(error)
      case error
      when Exception
        "#{error.class}: #{error.message}\n#{error.backtrace&.first(10)&.join("\n")}"
      when String
        error
      else
        error.to_s
      end
    end

    # Build the dotted_order string for trace ordering
    # Format: {timestamp}{id} for root, {parent_dotted_order}.{timestamp}{id} for children
    def build_dotted_order(parent_dotted_order)
      # Format timestamp as YYYYMMDDTHHMMSSffffffZ (compact ISO8601 with microseconds)
      timestamp = @start_time.strftime("%Y%m%dT%H%M%S%6NZ")
      order_part = "#{timestamp}#{@id}"

      if parent_dotted_order
        "#{parent_dotted_order}.#{order_part}"
      else
        order_part
      end
    end
  end
end
