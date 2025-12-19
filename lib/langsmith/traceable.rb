# frozen_string_literal: true

module Langsmith
  # Module that provides method decoration for automatic tracing.
  # Include this module in your class and use the `traceable` class method
  # to mark methods for tracing.
  #
  # @example
  #   class MyService
  #     include Langsmith::Traceable
  #
  #     traceable run_type: "llm"
  #     def call_llm(prompt)
  #       # automatically traced
  #     end
  #
  #     traceable run_type: "tool", name: "search"
  #     def search(query)
  #       # traced with custom name
  #     end
  #
  #     traceable run_type: "chain", tenant_id: "tenant-123"
  #     def process_for_tenant(data)
  #       # traced to specific tenant
  #     end
  #   end
  module Traceable
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Marks the next defined method as traceable
      def traceable(run_type: "chain", name: nil, metadata: nil, tags: nil, tenant_id: nil)
        @pending_traceable_options = {
          run_type: run_type,
          name: name,
          metadata: metadata,
          tags: tags,
          tenant_id: tenant_id
        }
      end

      def method_added(method_name)
        super

        return unless @pending_traceable_options

        options = @pending_traceable_options
        @pending_traceable_options = nil

        # Don't wrap private/protected methods that start with underscore
        return if method_name.to_s.start_with?("_langsmith_")

        wrap_method(method_name, options)
      end

      private

      def wrap_method(method_name, options)
        original_method = instance_method(method_name)
        trace_name = options[:name] || "#{name}##{method_name}"

        # Remove original method to avoid "method redefined" warning
        remove_method(method_name)

        define_method(method_name) do |*args, **kwargs, &block|
          Langsmith.trace(
            trace_name,
            run_type: options[:run_type],
            inputs: build_trace_inputs(args, kwargs, original_method),
            metadata: options[:metadata],
            tags: options[:tags],
            tenant_id: options[:tenant_id]
          ) do |_run|
            if kwargs.empty?
              original_method.bind(self).call(*args, &block)
            else
              original_method.bind(self).call(*args, **kwargs, &block)
            end
          end
        end
      end
    end

    private

    def build_trace_inputs(args, kwargs, method)
      params = method.parameters
      inputs = {}

      # Map positional arguments
      args.each_with_index do |arg, index|
        param = params[index]
        param_name = param ? param[1] : "arg#{index}"
        inputs[param_name] = serialize_input(arg)
      end

      # Map keyword arguments
      kwargs.each do |key, value|
        inputs[key] = serialize_input(value)
      end

      inputs
    end

    def serialize_input(value)
      case value
      when String, Numeric, TrueClass, FalseClass, NilClass
        value
      when Array
        value.map { |v| serialize_input(v) }
      when Hash
        value.transform_values { |v| serialize_input(v) }
      else
        value.to_s
      end
    end
  end
end
