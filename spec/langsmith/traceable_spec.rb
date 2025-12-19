# frozen_string_literal: true

RSpec.describe Langsmith::Traceable do
  before do
    Langsmith.reset_configuration!
    Langsmith::Context.clear!
  end

  let(:test_class) do
    Class.new do
      include Langsmith::Traceable

      def self.name
        "TestService"
      end

      traceable run_type: "chain"
      def simple_method(input)
        "processed: #{input}"
      end

      traceable run_type: "llm", name: "custom_name"
      def method_with_custom_name(prompt)
        "response to: #{prompt}"
      end

      traceable run_type: "tool"
      def method_with_kwargs(query:, limit: 10)
        "#{query} (limit: #{limit})"
      end

      def non_traced_method
        "not traced"
      end
    end
  end

  describe "traceable decorator" do
    context "when tracing is disabled" do
      before do
        allow(Langsmith).to receive(:tracing_enabled?).and_return(false)
      end

      it "executes the method normally" do
        service = test_class.new

        result = service.simple_method("test")

        expect(result).to eq("processed: test")
      end

      it "handles kwargs" do
        service = test_class.new

        result = service.method_with_kwargs(query: "search", limit: 5)

        expect(result).to eq("search (limit: 5)")
      end
    end

    context "when tracing is enabled" do
      let(:batch_processor) { instance_double(Langsmith::BatchProcessor) }

      before do
        allow(Langsmith).to receive(:tracing_enabled?).and_return(true)
        allow(Langsmith).to receive(:batch_processor).and_return(batch_processor)
        allow(batch_processor).to receive(:enqueue_create)
        allow(batch_processor).to receive(:enqueue_update)
      end

      it "traces the method execution" do
        service = test_class.new

        result = service.simple_method("test")

        expect(result).to eq("processed: test")
        expect(batch_processor).to have_received(:enqueue_create)
        expect(batch_processor).to have_received(:enqueue_update)
      end

      it "uses the method name in trace" do
        service = test_class.new
        captured_run = nil

        allow(batch_processor).to receive(:enqueue_create) do |run|
          captured_run = run
        end

        service.simple_method("test")

        expect(captured_run.name).to eq("TestService#simple_method")
      end

      it "uses custom name when specified" do
        service = test_class.new
        captured_run = nil

        allow(batch_processor).to receive(:enqueue_create) do |run|
          captured_run = run
        end

        service.method_with_custom_name("hello")

        expect(captured_run.name).to eq("custom_name")
      end

      it "captures inputs" do
        service = test_class.new
        captured_run = nil

        allow(batch_processor).to receive(:enqueue_create) do |run|
          captured_run = run
        end

        service.simple_method("test_input")

        expect(captured_run.inputs[:input]).to eq("test_input")
      end

      it "captures kwargs as inputs" do
        service = test_class.new
        captured_run = nil

        allow(batch_processor).to receive(:enqueue_create) do |run|
          captured_run = run
        end

        service.method_with_kwargs(query: "search", limit: 5)

        expect(captured_run.inputs[:query]).to eq("search")
        expect(captured_run.inputs[:limit]).to eq(5)
      end
    end
  end

  describe "non-traced methods" do
    it "are not affected by the module" do
      service = test_class.new

      result = service.non_traced_method

      expect(result).to eq("not traced")
    end
  end
end
