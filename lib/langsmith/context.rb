# frozen_string_literal: true

module Langsmith
  # Thread/Fiber-local context manager for maintaining the current trace stack.
  # This allows nested traces to automatically link to their parent runs.
  #
  # Each thread/fiber maintains its own trace stack, ensuring proper isolation
  # in concurrent environments. Uses Fiber.current storage when available (Ruby 3.2+)
  # to properly support async frameworks like Async, Falcon, etc.
  module Context
    CONTEXT_KEY = :langsmith_run_stack
    private_constant :CONTEXT_KEY

    class << self
      # Returns the current run stack for this thread/fiber.
      # Uses Fiber-local storage when available (Ruby 3.2+) for better
      # compatibility with async frameworks.
      def run_stack
        storage[CONTEXT_KEY] ||= []
      end

      private

      # Returns the appropriate storage mechanism.
      # Ruby 3.2+ has Fiber#storage for fiber-local variables.
      def storage
        if Fiber.current.respond_to?(:storage)
          Fiber.current.storage
        else
          Thread.current
        end
      end

      public

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

      # Clear the entire run stack (useful for testing)
      def clear!
        storage[CONTEXT_KEY] = []
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
    end
  end
end
