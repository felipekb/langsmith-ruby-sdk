# frozen_string_literal: true

RSpec.describe Langsmith do
  before do
    # NOTE: reset_configuration! is also called in spec_helper.rb
    # but we call it here explicitly along with Context.clear! for test isolation
    Langsmith::Context.clear!
  end

  describe ".configure" do
    it "yields configuration object" do
      described_class.configure do |config|
        config.api_key = "test_key"
        config.project = "test_project"
      end

      expect(described_class.configuration.api_key).to eq("test_key")
      expect(described_class.configuration.project).to eq("test_project")
    end

    it "validates configuration" do
      config = described_class.configuration
      config.tracing_enabled = true
      config.api_key = nil

      expect { config.validate! }.to raise_error(Langsmith::ConfigurationError)
    end
  end

  describe ".tracing_enabled?" do
    it "delegates to configuration" do
      described_class.configure do |config|
        config.api_key = "test_key"
        config.tracing_enabled = true
      end

      expect(described_class.tracing_enabled?).to be true
    end
  end

  describe ".trace" do
    context "when tracing is disabled" do
      before do
        allow(described_class).to receive(:tracing_enabled?).and_return(false)
      end

      it "executes the block and returns result" do
        result = described_class.trace("operation") { "result" }

        expect(result).to eq("result")
      end
    end

    context "when tracing is enabled" do
      let(:batch_processor) { instance_double(Langsmith::BatchProcessor) }

      before do
        allow(described_class).to receive(:tracing_enabled?).and_return(true)
        allow(described_class).to receive(:batch_processor).and_return(batch_processor)
        allow(batch_processor).to receive(:enqueue_create)
        allow(batch_processor).to receive(:enqueue_update)
      end

      it "creates a trace and executes the block" do
        result = described_class.trace("operation", run_type: "chain") { "result" }

        expect(result).to eq("result")
      end

      it "yields the run to the block" do
        described_class.trace("operation") do |run|
          expect(run).to be_a(Langsmith::Run)
          expect(run.name).to eq("operation")
        end
      end

      it "supports nested traces" do
        parent_id = nil
        child_parent_id = nil

        described_class.trace("parent", run_type: "chain") do |parent_run|
          parent_id = parent_run.id

          described_class.trace("child", run_type: "llm") do |child_run|
            child_parent_id = child_run.parent_run_id
          end
        end

        expect(child_parent_id).to eq(parent_id)
      end

      it "enqueues runs to batch processor" do
        described_class.trace("operation") { "result" }

        expect(batch_processor).to have_received(:enqueue_create)
        expect(batch_processor).to have_received(:enqueue_update)
      end
    end
  end

  describe ".current_run" do
    it "returns nil when not tracing" do
      expect(described_class.current_run).to be_nil
    end

    it "returns current run when tracing" do
      allow(described_class).to receive(:tracing_enabled?).and_return(true)
      batch_processor = instance_double(Langsmith::BatchProcessor)
      allow(described_class).to receive(:batch_processor).and_return(batch_processor)
      allow(batch_processor).to receive(:enqueue_create)
      allow(batch_processor).to receive(:enqueue_update)

      captured_run = nil
      described_class.trace("operation") do |_run|
        captured_run = described_class.current_run
      end

      expect(captured_run).not_to be_nil
    end
  end

  describe ".tracing?" do
    it "returns false when not in a trace" do
      expect(described_class.tracing?).to be false
    end

    it "returns true when inside a trace" do
      allow(described_class).to receive(:tracing_enabled?).and_return(true)
      batch_processor = instance_double(Langsmith::BatchProcessor)
      allow(described_class).to receive(:batch_processor).and_return(batch_processor)
      allow(batch_processor).to receive(:enqueue_create)
      allow(batch_processor).to receive(:enqueue_update)

      inside_trace = nil
      described_class.trace("operation") do
        inside_trace = described_class.tracing?
      end

      expect(inside_trace).to be true
    end
  end
end
