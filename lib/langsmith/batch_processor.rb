# frozen_string_literal: true

require "concurrent"

module Langsmith
  # Background processor that batches trace runs and sends them to LangSmith.
  # Uses concurrent-ruby for thread-safe operations.
  #
  # Thread Safety:
  # - Uses AtomicBoolean for atomic start/shutdown
  # - Uses a Mutex to protect flush_pending from concurrent access
  # - Uses Concurrent::Array for thread-safe pending queues
  class BatchProcessor
    # Entry types for the queue
    CREATE = :create
    UPDATE = :update
    SHUTDOWN = :shutdown

    def initialize(client: nil, batch_size: nil, flush_interval: nil)
      config = Langsmith.configuration
      @client = client || Client.new
      @batch_size = batch_size || config.batch_size
      @flush_interval = flush_interval || config.flush_interval

      @queue = Queue.new
      @running = Concurrent::AtomicBoolean.new(false)
      @worker_thread = Concurrent::AtomicReference.new(nil)
      @pending_creates = Concurrent::Array.new
      @pending_updates = Concurrent::Array.new
      @flush_task = nil
      @flush_mutex = Mutex.new
      @shutdown_hook_registered = false
    end

    def start
      return unless @running.make_true

      @worker_thread.set(create_worker_thread)
      @flush_task = create_flush_task
      @flush_task.execute

      register_shutdown_hook
    end

    def shutdown
      return unless @running.make_false

      @flush_task&.shutdown
      @queue << { type: SHUTDOWN }

      worker = @worker_thread.get
      if worker&.alive? && !worker.join(5)
        # Give the worker time to drain the queue gracefully
        log_error("Worker thread did not terminate within timeout", force: true)
      end

      flush_pending
    end

    def enqueue_create(run)
      enqueue(CREATE, run)
    end

    def enqueue_update(run)
      enqueue(UPDATE, run)
    end

    def flush
      flush_pending
    end

    def running?
      @running.true?
    end

    private

    def enqueue(type, run)
      unless run.is_a?(Run)
        log_error("enqueue expects a Run instance, got #{run.class}")
        return
      end

      ensure_started
      # Use to_h for creates (full data), to_update_h for updates (minimal PATCH payload)
      run_data = type == CREATE ? run.to_h : run.to_update_h
      @queue << { type: type, run_data: run_data, tenant_id: run.tenant_id }
    end

    def create_worker_thread
      Thread.new { worker_loop }.tap do |t|
        t.abort_on_exception = false
        t.report_on_exception = false
      end
    end

    def create_flush_task
      Concurrent::TimerTask.new(
        execution_interval: @flush_interval,
        run_now: false
      ) { safe_flush }
    end

    def register_shutdown_hook
      return if @shutdown_hook_registered

      @shutdown_hook_registered = true
      processor = self
      at_exit do
        processor.shutdown if processor.running?
      rescue StandardError => e
        warn "[Langsmith] Error during shutdown: #{e.message}" if ENV["LANGSMITH_DEBUG"]
      end
    end

    def ensure_started
      start unless running?
    end

    def worker_loop
      loop do
        entry = @queue.pop
        break if process_entry(entry) == :shutdown

        flush_if_batch_full
      rescue StandardError => e
        log_error("Batch processor error: #{e.message}")
      end
    end

    def process_entry(entry)
      case entry[:type]
      when CREATE
        @pending_creates << build_pending_entry(entry)
      when UPDATE
        @pending_updates << build_pending_entry(entry)
      when SHUTDOWN
        drain_queue
        flush_pending
        :shutdown
      end
    end

    def build_pending_entry(entry)
      { data: entry[:run_data], tenant_id: entry[:tenant_id] }
    end

    def drain_queue
      loop do
        entry = @queue.pop(true)
        process_entry(entry) unless entry[:type] == SHUTDOWN
      rescue ThreadError
        break
      end
    end

    def safe_flush
      flush_pending if has_pending?
    rescue StandardError => e
      log_error("Flush task error: #{e.message}")
    end

    def flush_if_batch_full
      flush_pending if batch_full?
    end

    def batch_full?
      pending_count >= @batch_size
    end

    def has_pending?
      pending_count.positive?
    end

    def pending_count
      @pending_creates.size + @pending_updates.size
    end

    def flush_pending
      @flush_mutex.synchronize do
        creates = extract_all(@pending_creates)
        updates = extract_all(@pending_updates)

        return if creates.empty? && updates.empty?

        send_batches(creates, updates)
      end
    end

    def extract_all(array)
      result = []
      result << array.shift until array.empty?
      result
    rescue ThreadError
      result
    end

    def send_batches(creates, updates)
      by_tenant = group_by_tenant(creates, updates)

      # Send POSTs first, then PATCHes (LangSmith needs runs created before updating)
      send_batch_type(by_tenant, :creates, :post_runs)
      send_batch_type(by_tenant, :updates, :patch_runs)
    end

    def group_by_tenant(creates, updates)
      {
        creates: creates.group_by { |e| e[:tenant_id] },
        updates: updates.group_by { |e| e[:tenant_id] }
      }
    end

    def send_batch_type(by_tenant, type_key, param_key)
      by_tenant[type_key].each do |tenant_id, entries|
        runs = entries.map { |e| e[:data] }
        next if runs.empty?

        send_to_api(tenant_id, param_key, runs)
      end
    end

    def send_to_api(tenant_id, param_key, runs)
      params = { post_runs: [], patch_runs: [], tenant_id: tenant_id }
      params[param_key] = runs

      @client.batch_ingest_raw(**params)
    rescue Client::APIError => e
      log_error("Failed to send #{param_key} for tenant #{tenant_id}: #{e.message}", force: true)
    rescue StandardError => e
      log_error("Unexpected error sending #{param_key}: #{e.message}")
    end

    def log_error(message, force: false)
      warn "[Langsmith] #{message}" if force || ENV["LANGSMITH_DEBUG"]
    end
  end
end
