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
end
