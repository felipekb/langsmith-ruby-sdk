# frozen_string_literal: true

RSpec.describe Langsmith::Configuration do
  subject(:config) { described_class.new }

  describe "#initialize" do
    it "loads api_key from environment" do
      ClimateControl.modify(LANGSMITH_API_KEY: "test_key") do
        new_config = described_class.new
        expect(new_config.api_key).to eq("test_key")
      end
    end

    it "sets default endpoint" do
      expect(config.endpoint).to eq("https://api.smith.langchain.com")
    end

    it "sets default project" do
      expect(config.project).to eq("default")
    end

    it "sets default batch_size" do
      expect(config.batch_size).to eq(100)
    end

    it "sets default flush_interval" do
      expect(config.flush_interval).to eq(1.0)
    end

    it "sets default tracing_enabled to false" do
      expect(config.tracing_enabled).to be false
    end
  end

  describe "#tracing_enabled?" do
    context "when tracing is enabled" do
      before { config.tracing_enabled = true }

      it "returns true" do
        expect(config.tracing_enabled?).to be true
      end
    end

    context "when tracing is disabled" do
      before { config.tracing_enabled = false }

      it "returns false" do
        expect(config.tracing_enabled?).to be false
      end
    end
  end

  describe "#tracing_possible?" do
    context "when tracing is enabled and api_key is present" do
      before do
        config.tracing_enabled = true
        config.api_key = "test_key"
      end

      it "returns true" do
        expect(config.tracing_possible?).to be true
      end
    end

    context "when tracing is disabled" do
      before do
        config.tracing_enabled = false
        config.api_key = "test_key"
      end

      it "returns false" do
        expect(config.tracing_possible?).to be false
      end
    end

    context "when api_key is not present" do
      before do
        config.tracing_enabled = true
        config.api_key = nil
      end

      it "returns false" do
        expect(config.tracing_possible?).to be false
      end
    end
  end

  describe "#validate!" do
    context "when tracing is enabled without api_key" do
      it "raises ConfigurationError" do
        config.tracing_enabled = true
        config.api_key = nil

        expect { config.validate! }.to raise_error(Langsmith::ConfigurationError)
      end
    end

    context "when tracing is enabled with api_key" do
      before do
        config.tracing_enabled = true
        config.api_key = "test_key"
      end

      it "does not raise" do
        expect { config.validate! }.not_to raise_error
      end
    end

    context "when tracing is disabled" do
      before do
        config.tracing_enabled = false
      end

      it "does not raise" do
        expect { config.validate! }.not_to raise_error
      end
    end
  end
end

# Simple helper for environment variable testing
module ClimateControl
  def self.modify(env_vars)
    old_values = {}
    env_vars.each do |key, value|
      key_s = key.to_s
      old_values[key_s] = ENV.fetch(key_s, nil)
      ENV[key_s] = value
    end
    yield
  ensure
    old_values.each do |key, value|
      ENV[key] = value
    end
  end
end
