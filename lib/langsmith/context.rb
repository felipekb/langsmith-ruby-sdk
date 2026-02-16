# frozen_string_literal: true

module Langsmith
  # Thread-local context manager for maintaining the current trace stack.
  # This allows nested traces to automatically link to their parent runs.
  #
  # Each thread maintains its own trace stack, ensuring proper isolation
  # in concurrent environments.
  #
  # Note: We use Thread.current instead of Fiber.storage for compatibility
  # across Ruby versions. Fiber.storage behavior differs between Ruby versions
  # and caused test failures on Ruby 3.2.
  module Context
    CONTEXT_KEY = :langsmith_run_stack
    EVALUATION_CONTEXT_KEY = :langsmith_evaluation_context
    EVALUATION_ROOT_RUN_ID_KEY = :langsmith_evaluation_root_run_id
    EVALUATION_ROOT_RUN_TENANT_ID_KEY = :langsmith_evaluation_root_run_tenant_id
    private_constant :CONTEXT_KEY, :EVALUATION_CONTEXT_KEY, :EVALUATION_ROOT_RUN_ID_KEY,
                     :EVALUATION_ROOT_RUN_TENANT_ID_KEY

    class << self
      # Returns the current run stack for this thread.
      def run_stack
        Thread.current[CONTEXT_KEY] ||= []
      end

      # Returns the current (topmost) run, or nil if no active trace
      def current_run
        run_stack.last
      end

      # Returns the current parent run ID for creating child runs
      def current_parent_run_id
        current_run&.id
      end

      # Push a run onto the context stack
      def push(run)
        run_stack.push(run)
        run
      end

      # Pop a run from the context stack
      def pop
        run_stack.pop
      end

      # Execute a block with a run pushed onto the stack
      def with_run(run)
        push(run)
        yield run
      ensure
        pop
      end

      # Clear the entire run stack and evaluation context (useful for testing)
      def clear!
        Thread.current[CONTEXT_KEY] = []
        Thread.current[EVALUATION_CONTEXT_KEY] = nil
        Thread.current[EVALUATION_ROOT_RUN_ID_KEY] = nil
        Thread.current[EVALUATION_ROOT_RUN_TENANT_ID_KEY] = nil
      end

      # Check if there's an active trace context
      def active?
        !run_stack.empty?
      end

      # Get the depth of the current trace (0 = root level)
      def depth
        run_stack.size
      end

      # Get the root run of the current trace tree
      def root_run
        run_stack.first
      end

      # Returns the current evaluation context, or nil when not in evaluation.
      # @return [Hash, nil] hash with :experiment_id and :example_id, or nil
      def evaluation_context
        Thread.current[EVALUATION_CONTEXT_KEY]
      end

      # Returns true when evaluation context is set.
      # @return [Boolean]
      def evaluating?
        !evaluation_context.nil?
      end

      # Stores the root run ID for the current evaluation example.
      # Called by RunTree when creating the first root run inside an evaluation block.
      #
      # @param run_id [String] the root run's ID
      def set_evaluation_root_run_id(run_id)
        Thread.current[EVALUATION_ROOT_RUN_ID_KEY] = run_id
      end

      # Returns the root run ID for the current evaluation example, or nil.
      # @return [String, nil]
      def evaluation_root_run_id
        Thread.current[EVALUATION_ROOT_RUN_ID_KEY]
      end

      # Stores the root run tenant ID for the current evaluation example.
      #
      # @param tenant_id [String, nil] the root run's tenant ID
      def set_evaluation_root_run_tenant_id(tenant_id)
        Thread.current[EVALUATION_ROOT_RUN_TENANT_ID_KEY] = tenant_id
      end

      # Returns the root run tenant ID for the current evaluation example, or nil.
      # @return [String, nil]
      def evaluation_root_run_tenant_id
        Thread.current[EVALUATION_ROOT_RUN_TENANT_ID_KEY]
      end

      # Execute a block with evaluation context set.
      # Context is cleared in ensure block even if the block raises.
      #
      # @param experiment_id [String] the experiment session ID
      # @param example_id [String] the dataset example ID
      def with_evaluation(experiment_id:, example_id:)
        Thread.current[EVALUATION_CONTEXT_KEY] = { experiment_id: experiment_id, example_id: example_id }
        yield
      ensure
        Thread.current[EVALUATION_CONTEXT_KEY] = nil
        Thread.current[EVALUATION_ROOT_RUN_ID_KEY] = nil
        Thread.current[EVALUATION_ROOT_RUN_TENANT_ID_KEY] = nil
      end
    end
  end
end
