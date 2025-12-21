# frozen_string_literal: true

RSpec.describe Langsmith::BatchProcessor do
  let(:client) { instance_double(Langsmith::Client) }
  let(:processor) { described_class.new(client: client, batch_size: 5, flush_interval: 0.05) }

  before do
    allow(client).to receive(:batch_ingest)
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

      expect(client).to have_received(:batch_ingest).at_least(:once)
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

      expect(client).to have_received(:batch_ingest).at_least(:once)
    end
  end

  describe "batching" do
    it "batches multiple runs together" do
      runs = 3.times.map { |i| Langsmith::Run.new(name: "run#{i}") }

      runs.each { |run| processor.enqueue_create(run) }

      processor.shutdown

      expect(client).to have_received(:batch_ingest).at_least(:once)
    end
  end

  describe "error handling" do
    it "continues processing after API errors" do
      call_count = 0
      allow(client).to receive(:batch_ingest) do
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

  describe "#flush" do
    it "drains queued items and sends them immediately" do
      run = Langsmith::Run.new(name: "flush_test")
      processor.enqueue_create(run)

      processor.flush

      expect(client).to have_received(:batch_ingest).with(
        post_runs: array_including(hash_including(name: "flush_test")),
        patch_runs: [],
        tenant_id: nil
      )
    end

    it "requeues failed batches and retries on next flush" do
      call_count = 0
      allow(client).to receive(:batch_ingest) do
        call_count += 1
        raise Langsmith::Client::APIError, "temporary failure" if call_count == 1
      end

      run = Langsmith::Run.new(name: "retry_test")
      processor.enqueue_create(run)

      expect { processor.flush }.not_to raise_error
      expect { processor.flush }.not_to raise_error

      expect(call_count).to be >= 2
      expect(client).to have_received(:batch_ingest).at_least(:twice)
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
      expect(client).to have_received(:batch_ingest).at_least(:twice)
    end
  end

  describe "buffer cap" do
    it "drops oldest entries when exceeding max_pending_entries" do
      capped_processor = described_class.new(client: client, batch_size: 5, flush_interval: 0.05, max_pending_entries: 1)
      allow(client).to receive(:batch_ingest)

      run1 = Langsmith::Run.new(name: "old")
      run2 = Langsmith::Run.new(name: "new")

      capped_processor.enqueue_create(run1)
      capped_processor.enqueue_create(run2)

      capped_processor.flush
      capped_processor.shutdown

      expect(client).to have_received(:batch_ingest).with(
        post_runs: array_including(hash_including(name: "new")),
        patch_runs: [],
        tenant_id: nil
      )
      expect(client).not_to have_received(:batch_ingest).with(
        post_runs: array_including(hash_including(name: "old")),
        patch_runs: [],
        tenant_id: nil
      )
    end
  end
end
