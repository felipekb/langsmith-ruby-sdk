# frozen_string_literal: true

require_relative "run"
require_relative "context"

module Langsmith
  # RunTree manages the creation and lifecycle of trace runs.
  # It handles parent-child relationships and coordinates with the batch processor.
  class RunTree
    attr_reader :run

    def initialize(
      name:,
      run_type: "chain",
      inputs: nil,
      metadata: nil,
      tags: nil,
      extra: nil,
      parent_run_id: nil,
      tenant_id: nil,
      project: nil
    )
      # If no explicit parent, check context for current parent
      effective_parent_id = parent_run_id || Context.current_parent_run_id

      # Inherit tenant_id from parent run if not explicitly set
      effective_tenant_id = tenant_id || Context.current_run&.tenant_id

      # Child traces must use the same project as their parent to keep the trace tree together.
      # Only root traces can set the project; children always inherit from parent.
      effective_project = Context.current_run&.session_name || project

      # Inherit trace_id from root run (parent's trace_id)
      # For root runs, trace_id will default to the run's own ID
      effective_trace_id = Context.current_run&.trace_id

      # Inherit dotted_order from parent for proper trace ordering
      parent_dotted_order = Context.current_run&.dotted_order

      # Inject evaluation context when present:
      # - session_id goes on ALL runs so the entire trace links to the experiment
      # - reference_example_id goes only on ROOT runs (no parent) per LangSmith API requirement
      eval_ctx = Context.evaluation_context
      effective_session_id = eval_ctx&.dig(:experiment_id)
      effective_ref_example_id = eval_ctx&.dig(:example_id) unless effective_parent_id

      @run = Run.new(
        name: name,
        run_type: run_type,
        inputs: inputs,
        parent_run_id: effective_parent_id,
        metadata: metadata,
        tags: tags,
        extra: extra,
        tenant_id: effective_tenant_id,
        session_name: effective_project,
        trace_id: effective_trace_id,
        parent_dotted_order: parent_dotted_order,
        reference_example_id: effective_ref_example_id,
        session_id: effective_session_id
      )

      @posted_start = false
      @posted_end = false
    end

    # Post the run start to LangSmith
    def post_start
      return if @posted_start || !Langsmith.tracing_enabled?

      Langsmith.batch_processor.enqueue_create(@run)
      @posted_start = true
    end

    # Post the run end to LangSmith
    def post_end
      return if @posted_end || !Langsmith.tracing_enabled?

      Langsmith.batch_processor.enqueue_update(@run)
      @posted_end = true
    end

    # Execute a block within this run's context
    def execute
      return yield(@run) unless Langsmith.tracing_enabled?

      post_start

      Context.with_run(@run) do
        result = yield(@run)
        @run.finish(outputs: sanitize_outputs(result))
        result
      end
    rescue StandardError => e
      @run.finish(error: e)
      raise
    ensure
      post_end if Langsmith.tracing_enabled?
    end

    # Convenience methods that delegate to the run
    def add_metadata(...)
      @run.add_metadata(...)
    end

    def add_tags(...)
      @run.add_tags(...)
    end

    def set_inputs(inputs)
      @run.inputs = inputs
    end

    def set_outputs(outputs)
      @run.outputs = outputs
    end

    def set_token_usage(...)
      @run.set_token_usage(...)
    end

    def set_model(...)
      @run.set_model(...)
    end

    def set_streaming_metrics(...)
      @run.set_streaming_metrics(...)
    end

    def id
      @run.id
    end

    def parent_run_id
      @run.parent_run_id
    end

    # Create a child run tree
    def create_child(name:, run_type: "chain", **kwargs)
      RunTree.new(
        name: name,
        run_type: run_type,
        parent_run_id: @run.id,
        **kwargs
      )
    end

    private

    # Sanitize block results to prevent circular references.
    # When users call methods like `run.add_metadata(...)` as the last line,
    # the Run object itself becomes the result, creating a circular reference.
    def sanitize_outputs(result)
      case result
      when Run, RunTree, nil
        # Run/RunTree objects would create circular reference, nil means no output
        nil
      else
        { result: result }
      end
    end
  end
end
