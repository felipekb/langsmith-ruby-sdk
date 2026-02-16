# frozen_string_literal: true

require_relative "evaluation/experiment_runner"

module Langsmith
  # Public API for running evaluations against LangSmith datasets.
  #
  # @example
  #   Langsmith::Evaluation.run(
  #     dataset_id: "dataset-uuid",
  #     experiment_name: "my-experiment"
  #   ) do |example|
  #     Langsmith.trace("eval", run_type: "chain", inputs: example[:inputs]) do
  #       my_app.call(example[:inputs])
  #     end
  #   end
  module Evaluation
    # Run an evaluation experiment against a dataset.
    #
    # @param dataset_id [String] the dataset to evaluate against
    # @param experiment_name [String] name for the experiment
    # @param description [String, nil] optional experiment description
    # @param metadata [Hash, nil] optional experiment metadata
    # @param evaluators [Hash] map of evaluator key to callable (see ExperimentRunner)
    # @param tenant_id [String, nil] tenant ID for dataset/session/feedback API calls
    # @yield [Hash] each dataset example
    # @return [Hash] summary with :experiment_id, :total, :succeeded, :failed, :results
    def self.run(dataset_id:, experiment_name:, description: nil, metadata: nil, evaluators: {}, tenant_id: nil, &block)
      ExperimentRunner.new(
        dataset_id: dataset_id,
        experiment_name: experiment_name,
        description: description,
        metadata: metadata,
        evaluators: evaluators,
        tenant_id: tenant_id,
        &block
      ).run
    end
  end
end
