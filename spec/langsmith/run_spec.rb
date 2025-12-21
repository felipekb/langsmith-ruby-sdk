# frozen_string_literal: true

RSpec.describe Langsmith::Run do
  describe "#initialize" do
    it "creates a run with required attributes" do
      run = described_class.new(name: "test_run")

      expect(run.name).to eq("test_run")
      expect(run.run_type).to eq("chain")
      expect(run.id).to match(/^[0-9a-f-]{36}$/)
      expect(run.start_time).to be_a(Time)
    end

    it "accepts optional attributes" do
      run = described_class.new(
        name: "test_run",
        run_type: "llm",
        inputs: { prompt: "hello" },
        metadata: { user_id: "123" },
        tags: ["test"]
      )

      expect(run.run_type).to eq("llm")
      expect(run.inputs).to eq({ prompt: "hello" })
      expect(run.metadata).to eq({ user_id: "123" })
      expect(run.tags).to eq(["test"])
    end

    it "validates run_type" do
      expect do
        described_class.new(name: "test", run_type: "invalid")
      end.to raise_error(ArgumentError, /Invalid run_type/)
    end

    it "accepts all valid run types" do
      %w[chain llm tool retriever prompt parser].each do |run_type|
        run = described_class.new(name: "test", run_type: run_type)
        expect(run.run_type).to eq(run_type)
      end
    end
  end

  describe "#finish" do
    let(:run) { described_class.new(name: "test_run") }

    it "sets end_time" do
      expect(run.end_time).to be_nil

      run.finish

      expect(run.end_time).to be_a(Time)
      expect(run.finished?).to be true
    end

    it "sets outputs" do
      run.finish(outputs: { result: "success" })

      expect(run.outputs).to eq({ result: "success" })
    end

    it "formats exception errors" do
      error = StandardError.new("Something went wrong")
      error.set_backtrace(%w[line1 line2])

      run.finish(error: error)

      expect(run.error).to include("StandardError: Something went wrong")
      expect(run.error).to include("line1")
    end

    it "formats string errors" do
      run.finish(error: "Custom error message")

      expect(run.error).to eq("Custom error message")
    end
  end

  describe "#add_metadata" do
    let(:run) { described_class.new(name: "test_run", metadata: { existing: "value" }) }

    it "merges new metadata" do
      run.add_metadata(new_key: "new_value")

      expect(run.metadata).to eq({ existing: "value", new_key: "new_value" })
    end

    it "returns nil to prevent circular references" do
      expect(run.add_metadata(key: "value")).to be_nil
    end
  end

  describe "#add_tags" do
    let(:run) { described_class.new(name: "test_run", tags: ["existing"]) }

    it "adds new tags" do
      run.add_tags("new_tag", "another_tag")

      expect(run.tags).to eq(%w[existing new_tag another_tag])
    end

    it "accepts array of tags" do
      run.add_tags(%w[tag1 tag2])

      expect(run.tags).to eq(%w[existing tag1 tag2])
    end
  end

  describe "#set_token_usage" do
    let(:run) { described_class.new(name: "test_run") }

    it "sets token usage in extra.metadata.usage_metadata" do
      run.set_token_usage(input_tokens: 10, output_tokens: 20)

      usage = run.extra.dig(:metadata, :usage_metadata)
      expect(usage[:input_tokens]).to eq(10)
      expect(usage[:output_tokens]).to eq(20)
      expect(usage[:total_tokens]).to eq(30)
    end

    it "allows explicit total_tokens" do
      run.set_token_usage(input_tokens: 10, output_tokens: 20, total_tokens: 35)

      usage = run.extra.dig(:metadata, :usage_metadata)
      expect(usage[:total_tokens]).to eq(35)
    end

    it "includes tokens in extra field in to_h" do
      run.set_token_usage(input_tokens: 100, output_tokens: 50)

      hash = run.to_h
      expect(hash[:extra][:metadata][:usage_metadata][:input_tokens]).to eq(100)
      expect(hash[:extra][:metadata][:usage_metadata][:output_tokens]).to eq(50)
      expect(hash[:extra][:metadata][:usage_metadata][:total_tokens]).to eq(150)
    end

    it "returns nil to prevent circular reference" do
      result = run.set_token_usage(input_tokens: 10, output_tokens: 20)
      expect(result).to be_nil
    end
  end

  describe "#set_model" do
    let(:run) { described_class.new(name: "test_run") }

    it "sets model info in extra.metadata" do
      run.set_model(model: "gpt-4o-mini", provider: "openai")

      expect(run.extra.dig(:metadata, :ls_model_name)).to eq("gpt-4o-mini")
      expect(run.extra.dig(:metadata, :ls_provider)).to eq("openai")
    end

    it "sets model without provider" do
      run.set_model(model: "claude-3-sonnet")

      expect(run.extra.dig(:metadata, :ls_model_name)).to eq("claude-3-sonnet")
      expect(run.extra.dig(:metadata, :ls_provider)).to be_nil
    end

    it "returns nil to prevent circular reference" do
      result = run.set_model(model: "gpt-4o-mini")
      expect(result).to be_nil
    end
  end

  describe "#set_streaming_metrics" do
    let(:run) { described_class.new(name: "test_run") }

    it "sets streaming metrics in extra.metadata.streaming_metrics" do
      run.set_streaming_metrics(
        time_to_first_token: 0.235,
        chunk_count: 42,
        tokens_per_second: 85.5
      )

      metrics = run.extra.dig(:metadata, :streaming_metrics)
      expect(metrics[:time_to_first_token_s]).to eq(0.235)
      expect(metrics[:chunk_count]).to eq(42)
      expect(metrics[:tokens_per_second]).to eq(85.5)
    end

    it "accepts partial metrics" do
      run.set_streaming_metrics(time_to_first_token: 0.5)

      metrics = run.extra.dig(:metadata, :streaming_metrics)
      expect(metrics[:time_to_first_token_s]).to eq(0.5)
      expect(metrics[:chunk_count]).to be_nil
    end

    it "returns nil to prevent circular reference" do
      result = run.set_streaming_metrics(time_to_first_token: 0.1)
      expect(result).to be_nil
    end
  end

  describe "#duration_ms" do
    let(:run) { described_class.new(name: "test_run") }

    it "returns nil when not finished" do
      expect(run.duration_ms).to be_nil
    end

    it "returns duration in milliseconds when finished" do
      run.finish

      expect(run.duration_ms).to be_a(Float)
      expect(run.duration_ms).to be >= 0
    end
  end

  describe "#to_h" do
    let(:run) do
      described_class.new(
        name: "test_run",
        run_type: "llm",
        inputs: { prompt: "hello" },
        metadata: { user_id: "123" }
      )
    end

    it "returns a hash suitable for JSON serialization" do
      hash = run.to_h

      expect(hash[:id]).to eq(run.id)
      expect(hash[:name]).to eq("test_run")
      expect(hash[:run_type]).to eq("llm")
      expect(hash[:inputs]).to eq({ prompt: "hello" })
      expect(hash[:metadata]).to eq({ user_id: "123" })
      expect(hash[:start_time]).to match(/^\d{4}-\d{2}-\d{2}T/)
    end

    it "excludes nil values" do
      hash = run.to_h

      expect(hash).not_to have_key(:outputs)
      expect(hash).not_to have_key(:error)
      expect(hash).not_to have_key(:end_time)
    end

    it "excludes empty collections" do
      simple_run = described_class.new(name: "simple")
      hash = simple_run.to_h

      expect(hash).not_to have_key(:extra)
      expect(hash).not_to have_key(:events)
      expect(hash).not_to have_key(:tags)
    end
  end
end
