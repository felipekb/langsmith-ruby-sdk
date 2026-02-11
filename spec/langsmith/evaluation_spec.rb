# frozen_string_literal: true

RSpec.describe Langsmith::Evaluation do
  describe ".run" do
    let(:runner) { instance_double(Langsmith::Evaluation::ExperimentRunner, run: { experiment_id: "exp-1" }) }
    let(:block) { proc { |example| example } }

    before do
      allow(Langsmith::Evaluation::ExperimentRunner).to receive(:new).and_return(runner)
    end

    it "delegates to ExperimentRunner with correct arguments" do
      described_class.run(dataset_id: "ds-1", experiment_name: "test", &block)

      expect(Langsmith::Evaluation::ExperimentRunner).to have_received(:new).with(
        dataset_id: "ds-1",
        experiment_name: "test",
        description: nil,
        metadata: nil,
        &block
      )
    end

    it "returns the result from ExperimentRunner#run" do
      result = described_class.run(dataset_id: "ds-1", experiment_name: "test", &block)

      expect(runner).to have_received(:run)
      expect(result[:experiment_id]).to eq("exp-1")
    end
  end
end
