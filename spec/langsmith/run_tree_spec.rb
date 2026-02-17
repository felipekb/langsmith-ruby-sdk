# frozen_string_literal: true

RSpec.describe Langsmith::RunTree do
  before do
    Langsmith.reset_configuration!
    Langsmith::Context.clear!
  end

  describe "#initialize" do
    it "creates a run with the given attributes" do
      run_tree = described_class.new(
        name: "test_operation",
        run_type: "llm",
        inputs: { prompt: "hello" }
      )

      expect(run_tree.run.name).to eq("test_operation")
      expect(run_tree.run.run_type).to eq("llm")
      expect(run_tree.run.inputs).to eq({ prompt: "hello" })
    end

    it "uses parent from context if not specified" do
      parent_run = Langsmith::Run.new(name: "parent")
      Langsmith::Context.push(parent_run)

      run_tree = described_class.new(name: "child")

      expect(run_tree.run.parent_run_id).to eq(parent_run.id)
    end

    it "uses explicit parent_run_id over context" do
      parent_run = Langsmith::Run.new(name: "context_parent")
      Langsmith::Context.push(parent_run)

      explicit_parent_id = "explicit-parent-id"
      run_tree = described_class.new(name: "child", parent_run_id: explicit_parent_id)

      expect(run_tree.run.parent_run_id).to eq(explicit_parent_id)
    end
  end

  describe "#execute" do
    context "when tracing is disabled" do
      before do
        allow(Langsmith).to receive(:tracing_enabled?).and_return(false)
      end

      it "executes the block and returns result" do
        run_tree = described_class.new(name: "test")

        result = run_tree.execute { "result" }

        expect(result).to eq("result")
      end

      it "does not modify context" do
        run_tree = described_class.new(name: "test")

        run_tree.execute do
          expect(Langsmith::Context.active?).to be false
        end
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

      it "pushes run to context during execution" do
        run_tree = described_class.new(name: "test")
        captured_run = nil

        run_tree.execute do
          captured_run = Langsmith::Context.current_run
        end

        expect(captured_run).to eq(run_tree.run)
        expect(Langsmith::Context.current_run).to be_nil
      end

      it "enqueues create at start" do
        run_tree = described_class.new(name: "test")

        run_tree.execute { "result" }

        expect(batch_processor).to have_received(:enqueue_create).with(run_tree.run)
      end

      it "enqueues update at end" do
        run_tree = described_class.new(name: "test")

        run_tree.execute { "result" }

        expect(batch_processor).to have_received(:enqueue_update).with(run_tree.run)
      end

      it "sets outputs from block return value" do
        run_tree = described_class.new(name: "test")

        run_tree.execute { { data: "result" } }

        expect(run_tree.run.outputs).to eq({ result: { data: "result" } })
      end

      it "captures errors and re-raises" do
        run_tree = described_class.new(name: "test")

        expect do
          run_tree.execute { raise StandardError, "test error" }
        end.to raise_error(StandardError, "test error")

        expect(run_tree.run.error).to include("test error")
      end

      it "enqueues update even when error occurs" do
        run_tree = described_class.new(name: "test")

        begin
          run_tree.execute { raise "error" }
        rescue StandardError
          # expected
        end

        expect(batch_processor).to have_received(:enqueue_update)
      end
    end
  end

  describe "#create_child" do
    it "creates a child run tree with parent_run_id set" do
      parent = described_class.new(name: "parent")
      child = parent.create_child(name: "child", run_type: "tool")

      expect(child.run.parent_run_id).to eq(parent.run.id)
      expect(child.run.run_type).to eq("tool")
    end
  end

  describe "evaluation context injection" do
    it "injects both reference_example_id and session_id into root runs" do
      Langsmith::Context.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        run_tree = described_class.new(name: "root_run")

        expect(run_tree.run.reference_example_id).to eq("ex-1")
        expect(run_tree.run.session_id).to eq("exp-1")
      end
    end

    it "injects session_id but not reference_example_id into child runs" do
      Langsmith::Context.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        parent_run = Langsmith::Run.new(name: "parent")
        Langsmith::Context.push(parent_run)

        run_tree = described_class.new(name: "child_run")

        expect(run_tree.run.session_id).to eq("exp-1")
        expect(run_tree.run.reference_example_id).to be_nil
      end
    end

    it "does not inject attributes when not in evaluation context" do
      run_tree = described_class.new(name: "normal_run")

      expect(run_tree.run.reference_example_id).to be_nil
      expect(run_tree.run.session_id).to be_nil
    end

    it "does not change existing run creation behavior when not evaluating" do
      parent_run = Langsmith::Run.new(name: "parent")
      Langsmith::Context.push(parent_run)

      run_tree = described_class.new(name: "child", inputs: { q: "hello" })

      expect(run_tree.run.parent_run_id).to eq(parent_run.id)
      expect(run_tree.run.inputs).to eq({ q: "hello" })
      expect(run_tree.run.reference_example_id).to be_nil
      expect(run_tree.run.session_id).to be_nil
    end

    it "registers root run ID and tenant in evaluation context when creating a root run" do
      Langsmith::Context.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        run_tree = described_class.new(name: "root_run", tenant_id: "tenant-123")

        expect(Langsmith::Context.evaluation_root_run_id).to eq(run_tree.run.id)
        expect(Langsmith::Context.evaluation_root_run_tenant_id).to eq("tenant-123")
      end
    end

    it "does not overwrite root run ID when creating a child run" do
      Langsmith::Context.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        root_tree = described_class.new(name: "root_run", tenant_id: "tenant-123")
        root_id = root_tree.run.id

        Langsmith::Context.push(root_tree.run)
        described_class.new(name: "child_run")

        expect(Langsmith::Context.evaluation_root_run_id).to eq(root_id)
        expect(Langsmith::Context.evaluation_root_run_tenant_id).to eq("tenant-123")
      end
    end
  end
end
