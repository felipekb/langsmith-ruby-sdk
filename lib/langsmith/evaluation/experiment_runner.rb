# frozen_string_literal: true

module Langsmith
  module Evaluation
    # Orchestrates running an evaluation experiment against a dataset.
    #
    # Fetches examples, creates an experiment, runs each example through
    # the user-provided block with evaluation context set, scores outputs
    # with evaluators, and returns a summary of results.
    class ExperimentRunner
      # @param dataset_id [String] the dataset to evaluate against
      # @param experiment_name [String] name for the experiment
      # @param description [String, nil] optional experiment description
      # @param metadata [Hash, nil] optional experiment metadata
      # @param evaluators [Hash] map of evaluator key to callable
      # @param block [Proc] block that receives each example and produces a result
      def initialize(dataset_id:, experiment_name:, description: nil, metadata: nil, evaluators: {}, &block)
        @dataset_id = dataset_id
        @experiment_name = experiment_name
        @description = description
        @metadata = metadata
        @evaluators = evaluators
        @block = block
      end

      # Run the evaluation experiment.
      #
      # @return [Hash] summary with :experiment_id, :total, :succeeded, :failed, :results
      def run
        examples = client.list_examples(dataset_id: @dataset_id)

        experiment = client.create_experiment(
          name: @experiment_name,
          dataset_id: @dataset_id,
          description: @description,
          metadata: @metadata
        )
        experiment_id = experiment[:id]

        results = examples.map { |example| run_example(example, experiment_id) }

        Langsmith.flush
        client.close_experiment(experiment_id: experiment_id, end_time: Time.now.utc.iso8601)

        build_summary(experiment_id, results)
      end

      private

      def client
        Langsmith.client
      end

      def run_example(example, experiment_id)
        outputs = nil
        run_id = nil

        begin
          Context.with_evaluation(experiment_id: experiment_id, example_id: example[:id]) do
            outputs = @block.call(example)
            run_id = Context.evaluation_root_run_id
          end
        rescue StandardError => e
          return { example_id: example[:id], run_id: nil, status: :error, error: e.message, feedback: nil }
        end

        feedback = run_evaluators(example, outputs, run_id)
        { example_id: example[:id], run_id: run_id, status: :success, error: nil, feedback: feedback }
      rescue StandardError => e
        { example_id: example[:id], run_id: run_id, status: :success, error: e.message, feedback: nil }
      end

      def run_evaluators(example, outputs, run_id)
        return nil if @evaluators.empty? || run_id.nil?

        Langsmith.flush
        run = fetch_run_with_retry(run_id)

        @evaluators.each_with_object({}) do |(key, evaluator), feedback|
          feedback[key] = execute_evaluator(key, evaluator, example, outputs, run_id, run)
        end
      end

      # LangSmith has indexing lag after batch ingest — the run may not be
      # queryable immediately. Retry a few times with a short delay.
      def fetch_run_with_retry(run_id, retries: 3, delay: 1)
        client.read_run(run_id: run_id)
      rescue Client::APIError => e
        raise unless e.status_code == 404 && retries.positive?

        sleep(delay)
        fetch_run_with_retry(run_id, retries: retries - 1, delay: delay)
      end

      def execute_evaluator(key, evaluator, example, outputs, run_id, run)
        result = evaluator.call(
          outputs: outputs,
          reference_outputs: example[:outputs],
          inputs: example[:inputs],
          run: run
        )
        return { score: nil, success: true, skipped: true } if result.nil?

        normalized = normalize_result(result)
        client.create_feedback(run_id: run_id, key: key.to_s, **normalized)
        normalized.merge(success: true)
      rescue StandardError => e
        { score: nil, success: false, error: e.message }
      end

      def normalize_result(result)
        case result
        when true  then { score: 1.0, value: nil, comment: nil }
        when false then { score: 0.0, value: nil, comment: nil }
        when Hash  then { score: result[:score], value: result[:value], comment: result[:comment] }
        else            { score: result, value: nil, comment: nil }
        end
      end

      def build_summary(experiment_id, results)
        {
          experiment_id: experiment_id,
          total: results.size,
          succeeded: results.count { |r| r[:status] == :success },
          failed: results.count { |r| r[:status] == :error },
          results: results
        }
      end
    end
  end
end
