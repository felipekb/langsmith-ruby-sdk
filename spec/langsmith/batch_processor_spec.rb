# frozen_string_literal: true

RSpec.describe Langsmith::BatchProcessor do
  let(:client) { instance_double(Langsmith::Client) }
  let(:processor) { described_class.new(client: client, batch_size: 5, flush_interval: 0.05) }

  before do
    allow(client).to receive(:batch_ingest_raw)
  end

  after do
    processor.shutdown
  end

  describe "#enqueue_create" do
    it "starts the processor if not running" do
      expect(processor.running?).to be false

      run = Langsmith::Run.new(name: "test")
      processor.enqueue_create(run)

      expect(processor.running?).to be true
    end
  end

  describe "#enqueue_update" do
    it "starts the processor if not running" do
      expect(processor.running?).to be false

      run = Langsmith::Run.new(name: "test")
      processor.enqueue_update(run)

      expect(processor.running?).to be true
    end
  end

  describe "#shutdown" do
    it "flushes pending runs before stopping" do
      run = Langsmith::Run.new(name: "test")
      processor.enqueue_create(run)

      processor.shutdown

      expect(client).to have_received(:batch_ingest_raw).at_least(:once)
    end

    it "stops the worker thread" do
      processor.start
      expect(processor.running?).to be true

      processor.shutdown

      expect(processor.running?).to be false
    end

    it "handles both creates and updates" do
      run1 = Langsmith::Run.new(name: "run1")
      run2 = Langsmith::Run.new(name: "run2")

      processor.enqueue_create(run1)
      processor.enqueue_update(run2)

      processor.shutdown

      expect(client).to have_received(:batch_ingest_raw).at_least(:once)
    end
  end

  describe "batching" do
    it "batches multiple runs together" do
      runs = 3.times.map { |i| Langsmith::Run.new(name: "run#{i}") }

      runs.each { |run| processor.enqueue_create(run) }

      processor.shutdown

      expect(client).to have_received(:batch_ingest_raw).at_least(:once)
    end
  end

  describe "error handling" do
    it "continues processing after API errors" do
      call_count = 0
      allow(client).to receive(:batch_ingest_raw) do
        call_count += 1
        raise Langsmith::Client::APIError, "test error" if call_count == 1
      end

      run1 = Langsmith::Run.new(name: "test1")
      run2 = Langsmith::Run.new(name: "test2")

      processor.enqueue_create(run1)
      processor.enqueue_create(run2)

      # Should not raise even with API error
      expect { processor.shutdown }.not_to raise_error
    end
  end

  describe "multi-tenant batching" do
    it "sends separate batches for different tenant IDs" do
      run1 = Langsmith::Run.new(name: "run1", tenant_id: "tenant-a")
      run2 = Langsmith::Run.new(name: "run2", tenant_id: "tenant-b")
      run3 = Langsmith::Run.new(name: "run3", tenant_id: "tenant-a")

      processor.enqueue_create(run1)
      processor.enqueue_create(run2)
      processor.enqueue_create(run3)

      processor.shutdown

      # Should receive at least 2 calls (one per tenant)
      expect(client).to have_received(:batch_ingest_raw).at_least(:twice)
    end
  end
end
