# frozen_string_literal: true

require "concurrent"

module Langsmith
  # Background processor that batches trace runs and sends them to LangSmith.
  # Uses concurrent-ruby for thread-safe operations.
  #
  # Thread Safety:
  # - Uses AtomicBoolean for atomic start/shutdown
  # - Uses @pending_mutex to protect all pending array access (add + extract)
  # - Uses @flush_mutex to ensure only one flush operation runs at a time
  # - HTTP calls happen outside locks to avoid blocking the worker
  class BatchProcessor
    # Entry types for the queue
    CREATE = :create
    UPDATE = :update
    SHUTDOWN = :shutdown

    def initialize(client: nil, batch_size: nil, flush_interval: nil, max_pending_entries: nil)
      config = Langsmith.configuration
      @client = client || Client.new
      @batch_size = batch_size || config.batch_size
      @flush_interval = flush_interval || config.flush_interval
      @max_pending_entries = max_pending_entries || config.max_pending_entries

      @queue = Queue.new
      @running = Concurrent::AtomicBoolean.new(false)
      @worker_thread = Concurrent::AtomicReference.new(nil)

      # Use regular arrays protected by mutex (simpler than Concurrent::Array)
      @pending_creates = []
      @pending_updates = []
      @pending_mutex = Mutex.new

      # Separate mutex for flush operations to prevent concurrent flushes
      @flush_mutex = Mutex.new

      @flush_task = nil
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
      ensure_started

      # Drain anything currently in the queue into pending, then flush.
      # Run a second drain pass to catch items enqueued while we were flushing.
      2.times do
        drain_queue_non_blocking
        flush_pending
      end
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

      # Snapshot run data on the calling thread to capture state at enqueue time.
      # This ensures CREATE captures initial state and UPDATE captures final state.
      # Trade-off: serialization happens on the hot path, but semantics are correct.
      run_data = type == CREATE ? run.to_h : run.to_update_h
      @queue << { type: type, run_data: run_data, tenant_id: run.tenant_id }
      trim_buffer_if_needed
    end

    def create_worker_thread
      Thread.new { worker_loop }.tap do |t|
        t.abort_on_exception = false
        # Enable reporting so we at least see errors in logs
        t.report_on_exception = true
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
        log_error("Batch processor error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      end
    end

    # Non-blocking drain of the queue into pending arrays.
    # Returns true if any entries were drained.
    def drain_queue_non_blocking
      drained = false

      loop do
        entry = pop_queue_non_blocking
        break unless entry

        process_entry(entry) unless entry[:type] == SHUTDOWN
        drained = true
      end

      drained
    end

    def process_entry(entry)
      case entry[:type]
      when CREATE
        add_pending(:creates, entry)
      when UPDATE
        add_pending(:updates, entry)
      when SHUTDOWN
        drain_queue
        flush_pending
        :shutdown
      end
    end

    # Thread-safe add to pending arrays
    def add_pending(type, entry)
      pending_entry = { data: entry[:run_data], tenant_id: entry[:tenant_id] }
      @pending_mutex.synchronize do
        case type
        when :creates
          @pending_creates << pending_entry
        when :updates
          @pending_updates << pending_entry
        end
      end
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

    # Approximate count - doesn't need to be perfectly synchronized
    # since it's just used for heuristic batch-full checks
    def pending_count
      @pending_mutex.synchronize do
        @pending_creates.size + @pending_updates.size
      end
    end

    def flush_pending
      # Only one flush at a time
      @flush_mutex.synchronize do
        # Atomically extract all pending items
        creates, updates = extract_pending

        return if creates.empty? && updates.empty?

        # HTTP calls happen outside @pending_mutex to avoid blocking the worker
        failed_creates, failed_updates = send_batches(creates, updates)

        requeue_failed(failed_creates, failed_updates)
      end
    end

    # Atomically extract and clear pending arrays
    # Returns [creates, updates] arrays
    def extract_pending
      @pending_mutex.synchronize do
        creates = @pending_creates.dup
        updates = @pending_updates.dup
        @pending_creates.clear
        @pending_updates.clear
        [creates, updates]
      end
    end

    def send_batches(creates, updates)
      by_tenant = group_by_tenant(creates, updates)

      # Send POSTs first, then PATCHes (LangSmith needs runs created before updating)
      failed_creates = send_batch_type(by_tenant, :creates, :post_runs)
      failed_updates = send_batch_type(by_tenant, :updates, :patch_runs)

      [failed_creates, failed_updates]
    end

    def group_by_tenant(creates, updates)
      {
        creates: creates.group_by { |e| e[:tenant_id] },
        updates: updates.group_by { |e| e[:tenant_id] }
      }
    end

    def send_batch_type(by_tenant, type_key, param_key)
      failed = []

      by_tenant[type_key].each do |tenant_id, entries|
        runs = entries.map { |e| e[:data] }
        next if runs.empty?

        success = send_to_api(tenant_id, param_key, runs)
        failed.concat(entries) unless success
      end

      failed
    end

    def send_to_api(tenant_id, param_key, runs)
      params = { post_runs: [], patch_runs: [], tenant_id: tenant_id }
      params[param_key] = runs

      @client.batch_ingest(**params)
      true
    rescue Client::APIError => e
      log_error("Failed to send #{param_key} for tenant #{tenant_id}: #{e.message}", force: true)
      false
    rescue StandardError => e
      # Force logging so unexpected failures don't silently drop traces
      log_error("Unexpected error sending #{param_key}: #{e.message}", force: true)
      false
    end

    def requeue_failed(failed_creates, failed_updates)
      return if failed_creates.empty? && failed_updates.empty?

      @pending_mutex.synchronize do
        @pending_creates.concat(failed_creates)
        @pending_updates.concat(failed_updates)
      end

      trim_buffer_if_needed
    end

    def trim_buffer_if_needed
      return unless @max_pending_entries

      drop_one_entry while current_buffer_size > @max_pending_entries
    end

    def current_buffer_size
      queue_size = @queue.size
      pending_size = @pending_mutex.synchronize { @pending_creates.size + @pending_updates.size }
      queue_size + pending_size
    end

    def drop_one_entry
      entry = pop_queue_non_blocking
      entry ||= pop_pending_non_blocking
      log_dropped(entry) if entry
    end

    def pop_queue_non_blocking
      @queue.pop(true)
    rescue ThreadError
      nil
    end

    def pop_pending_non_blocking
      @pending_mutex.synchronize do
        return @pending_creates.shift unless @pending_creates.empty?
        return @pending_updates.shift unless @pending_updates.empty?
      end
      nil
    end

    def log_dropped(entry)
      return unless ENV["LANGSMITH_DEBUG"]

      log_error(
        "Dropped run entry due to max_pending_entries cap (type: #{entry[:type]}, tenant: #{entry[:tenant_id]})"
      )
    end

    def log_error(message, force: false)
      warn "[Langsmith] #{message}" if force || ENV["LANGSMITH_DEBUG"]
    end
  end
end
