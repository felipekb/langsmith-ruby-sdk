# frozen_string_literal: true

RSpec.describe Langsmith::Context do
  before do
    described_class.clear!
  end

  describe ".current_run" do
    it "returns nil when no run is active" do
      expect(described_class.current_run).to be_nil
    end

    it "returns the current run when one is pushed" do
      run = Langsmith::Run.new(name: "test")
      described_class.push(run)

      expect(described_class.current_run).to eq(run)
    end
  end

  describe ".push and .pop" do
    it "maintains a stack of runs" do
      run1 = Langsmith::Run.new(name: "run1")
      run2 = Langsmith::Run.new(name: "run2")

      described_class.push(run1)
      described_class.push(run2)

      expect(described_class.current_run).to eq(run2)

      described_class.pop
      expect(described_class.current_run).to eq(run1)

      described_class.pop
      expect(described_class.current_run).to be_nil
    end
  end

  describe ".with_run" do
    it "pushes run during block execution and pops after" do
      run = Langsmith::Run.new(name: "test")

      described_class.with_run(run) do
        expect(described_class.current_run).to eq(run)
      end

      expect(described_class.current_run).to be_nil
    end

    it "pops the run even if block raises" do
      run = Langsmith::Run.new(name: "test")

      expect do
        described_class.with_run(run) do
          raise "error"
        end
      end.to raise_error("error")

      expect(described_class.current_run).to be_nil
    end
  end

  describe ".current_parent_run_id" do
    it "returns nil when no run is active" do
      expect(described_class.current_parent_run_id).to be_nil
    end

    it "returns the id of the current run" do
      run = Langsmith::Run.new(name: "test")
      described_class.push(run)

      expect(described_class.current_parent_run_id).to eq(run.id)
    end
  end

  describe ".active?" do
    it "returns false when stack is empty" do
      expect(described_class.active?).to be false
    end

    it "returns true when stack has runs" do
      described_class.push(Langsmith::Run.new(name: "test"))

      expect(described_class.active?).to be true
    end
  end

  describe ".depth" do
    it "returns 0 for empty stack" do
      expect(described_class.depth).to eq(0)
    end

    it "returns correct depth" do
      described_class.push(Langsmith::Run.new(name: "run1"))
      described_class.push(Langsmith::Run.new(name: "run2"))

      expect(described_class.depth).to eq(2)
    end
  end

  describe ".root_run" do
    it "returns nil when stack is empty" do
      expect(described_class.root_run).to be_nil
    end

    it "returns the first run pushed" do
      run1 = Langsmith::Run.new(name: "run1")
      run2 = Langsmith::Run.new(name: "run2")

      described_class.push(run1)
      described_class.push(run2)

      expect(described_class.root_run).to eq(run1)
    end
  end

  describe "thread isolation" do
    it "maintains separate stacks per thread" do
      run1 = Langsmith::Run.new(name: "main_thread")
      described_class.push(run1)

      thread_run = nil
      thread = Thread.new do
        thread_run = Langsmith::Run.new(name: "other_thread")
        described_class.push(thread_run)
        expect(described_class.current_run).to eq(thread_run)
      end
      thread.join

      expect(described_class.current_run).to eq(run1)
    end
  end

  describe ".evaluation_context" do
    it "returns nil when not in evaluation" do
      expect(described_class.evaluation_context).to be_nil
    end
  end

  describe ".evaluating?" do
    it "returns false when not in evaluation" do
      expect(described_class.evaluating?).to be false
    end
  end

  describe ".with_evaluation" do
    it "sets context during block and clears after" do
      described_class.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        ctx = described_class.evaluation_context
        expect(ctx[:experiment_id]).to eq("exp-1")
        expect(ctx[:example_id]).to eq("ex-1")
        expect(described_class.evaluating?).to be true
      end

      expect(described_class.evaluation_context).to be_nil
      expect(described_class.evaluating?).to be false
    end

    it "clears context even if block raises" do
      expect do
        described_class.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
          raise "boom"
        end
      end.to raise_error("boom")

      expect(described_class.evaluation_context).to be_nil
      expect(described_class.evaluating?).to be false
    end
  end

  describe "evaluation thread isolation" do
    it "maintains separate evaluation contexts per thread" do
      described_class.with_evaluation(experiment_id: "main-exp", example_id: "main-ex") do
        thread_ctx = nil
        thread = Thread.new do
          expect(described_class.evaluating?).to be false
          described_class.with_evaluation(experiment_id: "t-exp", example_id: "t-ex") do
            thread_ctx = described_class.evaluation_context
          end
        end
        thread.join

        expect(thread_ctx[:experiment_id]).to eq("t-exp")
        expect(described_class.evaluation_context[:experiment_id]).to eq("main-exp")
      end
    end
  end

  describe ".set_evaluation_root_run_id / .evaluation_root_run_id" do
    it "stores and retrieves the root run ID" do
      described_class.set_evaluation_root_run_id("run-123")

      expect(described_class.evaluation_root_run_id).to eq("run-123")
    end

    it "returns nil when not in evaluation" do
      expect(described_class.evaluation_root_run_id).to be_nil
    end

    it "is cleared after with_evaluation block completes" do
      described_class.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        described_class.set_evaluation_root_run_id("run-456")
        expect(described_class.evaluation_root_run_id).to eq("run-456")
      end

      expect(described_class.evaluation_root_run_id).to be_nil
    end
  end

  describe ".set_evaluation_root_run_tenant_id / .evaluation_root_run_tenant_id" do
    it "stores and retrieves the root run tenant ID" do
      described_class.set_evaluation_root_run_tenant_id("tenant-123")

      expect(described_class.evaluation_root_run_tenant_id).to eq("tenant-123")
    end

    it "returns nil when not in evaluation" do
      expect(described_class.evaluation_root_run_tenant_id).to be_nil
    end

    it "is cleared after with_evaluation block completes" do
      described_class.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        described_class.set_evaluation_root_run_tenant_id("tenant-456")
        expect(described_class.evaluation_root_run_tenant_id).to eq("tenant-456")
      end

      expect(described_class.evaluation_root_run_tenant_id).to be_nil
    end
  end

  describe ".clear!" do
    it "also clears evaluation context" do
      described_class.with_evaluation(experiment_id: "exp-1", example_id: "ex-1") do
        described_class.clear!

        expect(described_class.evaluation_context).to be_nil
        expect(described_class.evaluating?).to be false
      end
    end

    it "also clears evaluation root run ID" do
      described_class.set_evaluation_root_run_id("run-789")
      described_class.clear!

      expect(described_class.evaluation_root_run_id).to be_nil
    end

    it "also clears evaluation root run tenant ID" do
      described_class.set_evaluation_root_run_tenant_id("tenant-789")
      described_class.clear!

      expect(described_class.evaluation_root_run_tenant_id).to be_nil
    end
  end
end
