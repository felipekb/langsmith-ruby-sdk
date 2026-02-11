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

  describe "evaluator support" do
    before do
      allow(Langsmith::Context).to receive(:evaluation_root_run_id).and_return("run-abc")
      allow(client).to receive(:read_run)
        .and_return({ id: "run-abc", inputs: { q: "hi" }, outputs: { a: "bye" }, total_tokens: 10 })
      allow(client).to receive(:create_feedback)
    end

    def run_with_evaluators(evaluators, &block)
      block ||= proc { |_example| { answer: "result" } }
      described_class.new(
        dataset_id: dataset_id,
        experiment_name: experiment_name,
        evaluators: evaluators,
        &block
      ).run
    end

    it "calls evaluators with correct keyword arguments" do
      all_calls = []
      evaluator = lambda { |outputs:, reference_outputs:, inputs:, run:|
        all_calls << { outputs: outputs, reference_outputs: reference_outputs, inputs: inputs, run: run }
        1.0
      }

      run_with_evaluators({ correctness: evaluator })

      first_call = all_calls.first
      expect(first_call[:outputs]).to eq({ answer: "result" })
      expect(first_call[:reference_outputs]).to eq(examples.first[:outputs])
      expect(first_call[:inputs]).to eq(examples.first[:inputs])
      expect(first_call[:run]).to eq({ id: "run-abc", inputs: { q: "hi" }, outputs: { a: "bye" }, total_tokens: 10 })
    end

    it "calls create_feedback for each evaluator with key and score" do
      evaluators = {
        correctness: ->(**_kwargs) { 0.9 },
        relevance: ->(**_kwargs) { 0.8 }
      }

      run_with_evaluators(evaluators)

      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "correctness", score: 0.9, value: nil, comment: nil
      ).at_least(:once)
      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "relevance", score: 0.8, value: nil, comment: nil
      ).at_least(:once)
    end

    it "uses Float return as score directly" do
      run_with_evaluators({ metric: ->(**_kwargs) { 0.75 } })

      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "metric", score: 0.75, value: nil, comment: nil
      ).at_least(:once)
    end

    it "converts true to 1.0" do
      run_with_evaluators({ metric: ->(**_kwargs) { true } })

      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "metric", score: 1.0, value: nil, comment: nil
      ).at_least(:once)
    end

    it "converts false to 0.0" do
      run_with_evaluators({ metric: ->(**_kwargs) { false } })

      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "metric", score: 0.0, value: nil, comment: nil
      ).at_least(:once)
    end

    it "extracts score, value, and comment from Hash return" do
      evaluator = ->(**_kwargs) { { score: 0.5, value: "partial", comment: "half right" } }

      run_with_evaluators({ metric: evaluator })

      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "metric", score: 0.5, value: "partial", comment: "half right"
      ).at_least(:once)
    end

    it "skips feedback when evaluator returns nil" do
      run_with_evaluators({ metric: ->(**_kwargs) {} })

      expect(client).not_to have_received(:create_feedback)
    end

    it "does not stop other evaluators when one raises" do
      bad = ->(**_kwargs) { raise "evaluator boom" }
      good = ->(**_kwargs) { 1.0 }

      run_with_evaluators({ bad_eval: bad, good_eval: good })

      expect(client).to have_received(:create_feedback).with(
        run_id: "run-abc", key: "good_eval", score: 1.0, value: nil, comment: nil
      ).at_least(:once)
    end

    it "reports evaluator errors in per-example feedback results" do
      bad = ->(**_kwargs) { raise "evaluator boom" }

      result = run_with_evaluators({ bad_eval: bad })

      feedback = result[:results].first[:feedback]
      expect(feedback[:bad_eval][:success]).to be false
      expect(feedback[:bad_eval][:error]).to eq("evaluator boom")
    end

    it "includes run_id in per-example results" do
      result = run_with_evaluators({ metric: ->(**_kwargs) { 1.0 } })

      expect(result[:results].first[:run_id]).to eq("run-abc")
    end

    it "includes feedback details in per-example results" do
      result = run_with_evaluators({ metric: ->(**_kwargs) { 0.9 } })

      feedback = result[:results].first[:feedback]
      expect(feedback[:metric]).to include(score: 0.9, success: true)
    end

    it "does not call evaluators when no evaluators are provided" do
      result = run_experiment { |_example| { answer: "result" } }

      expect(client).not_to have_received(:create_feedback)
      expect(result[:results].first[:feedback]).to be_nil
    end

    it "does not call evaluators when the user block raises" do
      evaluator = ->(**_kwargs) { 1.0 }

      result = run_with_evaluators({ metric: evaluator }) { |_example| raise "block error" }

      expect(client).not_to have_received(:create_feedback)
      expect(result[:results].first[:status]).to eq(:error)
    end
  end
end
