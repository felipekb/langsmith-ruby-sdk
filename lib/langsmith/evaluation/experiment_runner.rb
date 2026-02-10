# frozen_string_literal: true

module Langsmith
  module Evaluation
    # Orchestrates running an evaluation experiment against a dataset.
    #
    # Fetches examples, creates an experiment, runs each example through
    # the user-provided block with evaluation context set, and returns
    # a summary of results.
    class ExperimentRunner
      # @param dataset_id [String] the dataset to evaluate against
      # @param experiment_name [String] name for the experiment
      # @param description [String, nil] optional experiment description
      # @param metadata [Hash, nil] optional experiment metadata
      # @param block [Proc] block that receives each example and produces a result
      def initialize(dataset_id:, experiment_name:, description: nil, metadata: nil, &block)
        @dataset_id = dataset_id
        @experiment_name = experiment_name
        @description = description
        @metadata = metadata
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
        Context.with_evaluation(experiment_id: experiment_id, example_id: example[:id]) do
          @block.call(example)
        end
        { example_id: example[:id], status: :success, error: nil }
      rescue StandardError => e
        { example_id: example[:id], status: :error, error: e.message }
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
