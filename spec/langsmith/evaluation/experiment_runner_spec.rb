# frozen_string_literal: true

RSpec.describe Langsmith::Evaluation::ExperimentRunner do
  let(:client) { instance_double(Langsmith::Client) }
  let(:dataset_id) { "dataset-123" }
  let(:experiment_name) { "test-experiment" }

  let(:examples) do
    [
      { id: "ex-1", inputs: { question: "What is Ruby?" }, outputs: { answer: "A language" } },
      { id: "ex-2", inputs: { question: "What is Rails?" }, outputs: { answer: "A framework" } }
    ]
  end

  let(:experiment_response) { { id: "exp-1", name: experiment_name } }

  before do
    allow(Langsmith).to receive(:client).and_return(client)
    allow(Langsmith).to receive(:flush)
    allow(client).to receive(:list_examples).and_return(examples)
    allow(client).to receive(:create_experiment).and_return(experiment_response)
    allow(client).to receive(:close_experiment)
  end

  def run_experiment(&block)
    described_class.new(
      dataset_id: dataset_id,
      experiment_name: experiment_name,
      &block
    ).run
  end

  describe "#run" do
    it "fetches examples from the dataset" do
      run_experiment { |example| example }

      expect(client).to have_received(:list_examples).with(dataset_id: dataset_id)
    end

    it "creates an experiment with correct parameters" do
      run_experiment { |example| example }

      expect(client).to have_received(:create_experiment).with(
        name: experiment_name,
        dataset_id: dataset_id,
        description: nil,
        metadata: nil
      )
    end

    it "forwards optional description and metadata to create_experiment" do
      described_class.new(
        dataset_id: dataset_id,
        experiment_name: experiment_name,
        description: "A test",
        metadata: { version: 1 }
      ) { |example| example }.run

      expect(client).to have_received(:create_experiment).with(
        name: experiment_name,
        dataset_id: dataset_id,
        description: "A test",
        metadata: { version: 1 }
      )
    end

    it "calls the block for each example" do
      received = []
      run_experiment { |example| received << example }

      expect(received).to eq(examples)
    end

    it "sets evaluation context for each example" do
      captured_contexts = []

      run_experiment do |_example|
        captured_contexts << Langsmith::Context.evaluation_context&.dup
      end

      expect(captured_contexts[0]).to eq({ experiment_id: "exp-1", example_id: "ex-1" })
      expect(captured_contexts[1]).to eq({ experiment_id: "exp-1", example_id: "ex-2" })
    end

    it "closes the experiment after running" do
      run_experiment { |example| example }

      expect(client).to have_received(:close_experiment) do |args|
        expect(args[:experiment_id]).to eq("exp-1")
        expect(args[:end_time]).to be_a(String)
      end
    end

    it "continues on error and tracks failures" do
      call_count = 0

      result = run_experiment do |_example|
        call_count += 1
        raise "boom" if call_count == 1

        "ok"
      end

      expect(call_count).to eq(2)
      expect(result[:failed]).to eq(1)
      expect(result[:succeeded]).to eq(1)
    end

    it "returns a summary hash with counts and experiment_id" do
      result = run_experiment { |example| example }

      expect(result[:experiment_id]).to eq("exp-1")
      expect(result[:total]).to eq(2)
      expect(result[:succeeded]).to eq(2)
      expect(result[:failed]).to eq(0)
    end

    it "returns per-example results with example_id and status" do
      result = run_experiment { |example| example }

      expect(result[:results]).to be_an(Array)
      expect(result[:results].size).to eq(2)
      expect(result[:results].first).to include(:example_id, :status)
    end

    it "flushes traces before returning" do
      run_experiment { |example| example }

      expect(Langsmith).to have_received(:flush)
    end
  end
end
