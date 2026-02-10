# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"
require "faraday/retry"
require "json"

module Langsmith
  # HTTP client for communicating with the LangSmith API.
  # Handles authentication, retries, and batch operations.
  class Client
    # Raised when API requests fail.
    class APIError < Langsmith::Error
      # @return [Integer, nil] HTTP status code
      attr_reader :status_code

      # @return [Hash, String, nil] response body
      attr_reader :response_body

      # @param message [String] error message
      # @param status_code [Integer, nil] HTTP status code
      # @param response_body [Hash, String, nil] response body
      def initialize(message, status_code: nil, response_body: nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
      end
    end

    RETRYABLE_EXCEPTIONS = [
      Faraday::ConnectionFailed,
      Faraday::TimeoutError
    ].freeze

    RETRY_STATUSES = [429, 500, 502, 503, 504].freeze

    # Creates a new Client instance.
    #
    # @param api_key [String, nil] API key (defaults to configuration)
    # @param endpoint [String, nil] API endpoint (defaults to configuration)
    # @param timeout [Integer, nil] request timeout in seconds (defaults to configuration)
    # @param max_retries [Integer, nil] max retry attempts (defaults to configuration)
    def initialize(api_key: nil, endpoint: nil, timeout: nil, max_retries: nil)
      config = Langsmith.configuration
      @api_key = api_key || config.api_key
      @endpoint = endpoint || config.endpoint
      @timeout = timeout || config.timeout
      @max_retries = max_retries || config.max_retries
    end

    # Create a new run.
    #
    # @param run [Run] the run to create
    # @return [Hash] API response
    # @raise [APIError] if the request fails
    def create_run(run)
      post("/runs", run.to_h, tenant_id: run.tenant_id)
    end

    # Update an existing run (typically when it ends).
    #
    # @param run [Run] the run to update
    # @return [Hash] API response
    # @raise [APIError] if the request fails
    def update_run(run)
      patch("/runs/#{run.id}", run.to_h, tenant_id: run.tenant_id)
    end

    # Batch create/update runs using pre-serialized hashes.
    # Used by BatchProcessor which snapshots run data at enqueue time.
    #
    # @param post_runs [Array<Hash>] run hashes to create
    # @param patch_runs [Array<Hash>] run hashes to update
    # @param tenant_id [String, nil] tenant ID for the request
    # @return [Hash, nil] API response
    # @raise [APIError] if the request fails
    def batch_ingest(post_runs: [], patch_runs: [], tenant_id: nil)
      return if post_runs.empty? && patch_runs.empty?

      payload = {}
      payload[:post] = post_runs unless post_runs.empty?
      payload[:patch] = patch_runs unless patch_runs.empty?

      post("/runs/batch", payload, tenant_id: tenant_id)
    end

    # List examples from a LangSmith dataset.
    #
    # @param dataset_id [String] the dataset ID to fetch examples from
    # @param limit [Integer, nil] max number of examples to return (API max: 100)
    # @param offset [Integer, nil] number of examples to skip
    # @param tenant_id [String, nil] tenant ID (falls back to configured tenant_id)
    # @return [Array<Hash>] array of example objects
    # @raise [APIError] if the request fails
    def list_examples(dataset_id:, limit: nil, offset: nil, tenant_id: nil)
      params = { dataset: dataset_id }
      params[:limit] = limit if limit
      params[:offset] = offset if offset

      get("/api/v1/examples", params: params, tenant_id: resolve_tenant_id(tenant_id))
    end

    # Create a new experiment (tracer session) linked to a dataset.
    #
    # @param name [String] experiment name
    # @param dataset_id [String] reference dataset ID
    # @param description [String, nil] optional experiment description
    # @param metadata [Hash, nil] optional metadata (stored as `extra`)
    # @param tenant_id [String, nil] tenant ID (falls back to configured tenant_id)
    # @return [Hash] the created experiment object
    # @raise [APIError] if the request fails
    def create_experiment(name:, dataset_id:, description: nil, metadata: nil, tenant_id: nil)
      payload = {
        name: name,
        reference_dataset_id: dataset_id,
        start_time: Time.now.utc.iso8601
      }
      payload[:description] = description if description
      payload[:extra] = metadata if metadata

      post("/api/v1/sessions", payload, tenant_id: resolve_tenant_id(tenant_id))
    end

    # Close an experiment by setting its end time.
    #
    # @param experiment_id [String] the experiment (session) ID
    # @param end_time [String] ISO-8601 end time
    # @param tenant_id [String, nil] tenant ID (falls back to configured tenant_id)
    # @return [Hash] the updated experiment object
    # @raise [APIError] if the request fails
    def close_experiment(experiment_id:, end_time:, tenant_id: nil)
      patch("/api/v1/sessions/#{experiment_id}", { end_time: end_time }, tenant_id: resolve_tenant_id(tenant_id))
    end

    # Create feedback (a score/annotation) on a run.
    #
    # @param run_id [String] UUID of the run to attach feedback to
    # @param key [String] metric name (e.g. "correctness")
    # @param score [Numeric, nil] numeric score (typically 0.0-1.0)
    # @param value [String, nil] categorical value (alternative to score)
    # @param comment [String, nil] explanation or reasoning
    # @param tenant_id [String, nil] tenant ID (falls back to configured tenant_id)
    # @return [Hash] the created feedback object
    # @raise [APIError] if the request fails
    def create_feedback(run_id:, key:, score: nil, value: nil, comment: nil, tenant_id: nil)
      payload = { run_id: run_id, key: key }
      payload[:score] = score if score
      payload[:value] = value if value
      payload[:comment] = comment if comment

      post("/api/v1/feedback", payload, tenant_id: resolve_tenant_id(tenant_id))
    end

    private

    def resolve_tenant_id(tenant_id)
      tenant_id || Langsmith.configuration.tenant_id
    end

    def get(path, params: {}, tenant_id: nil)
      response = connection.get(path, params) do |req|
        req.headers["X-Tenant-Id"] = tenant_id if tenant_id
      end
      handle_response(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise APIError, "Network error: #{e.message}"
    rescue Faraday::Error => e
      raise APIError, "Request failed: #{e.message}" unless e.respond_to?(:response) && e.response

      handle_response(e.response)
    end

    def connection
      @connection ||= Faraday.new(url: @endpoint) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: true }
        f.request :retry,
                  max: @max_retries,
                  interval: 0.5,
                  interval_randomness: 0.5,
                  backoff_factor: 2,
                  exceptions: RETRYABLE_EXCEPTIONS,
                  retry_statuses: RETRY_STATUSES

        f.headers["X-API-Key"] = @api_key
        f.headers["User-Agent"] = "langsmith-sdk-ruby/#{Langsmith::VERSION}"

        f.options.timeout = @timeout
        f.options.open_timeout = @timeout

        f.adapter :net_http_persistent
      end
    end

    def post(path, body, tenant_id: nil)
      response = connection.post(path, body) do |req|
        req.headers["X-Tenant-Id"] = tenant_id if tenant_id
      end
      handle_response(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise APIError, "Network error: #{e.message}"
    rescue Faraday::Error => e
      # Raised by retry middleware when retries are exhausted
      raise APIError, "Request failed: #{e.message}" unless e.respond_to?(:response) && e.response

      handle_response(e.response)
    end

    def patch(path, body, tenant_id: nil)
      response = connection.patch(path, body) do |req|
        req.headers["X-Tenant-Id"] = tenant_id if tenant_id
      end
      handle_response(response)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise APIError, "Network error: #{e.message}"
    rescue Faraday::Error => e
      # Raised by retry middleware when retries are exhausted
      raise APIError, "Request failed: #{e.message}" unless e.respond_to?(:response) && e.response

      handle_response(e.response)
    end

    def handle_response(response)
      case response.status
      when 200..299
        response.body
      when 401
        raise APIError.new("Unauthorized: Invalid API key", status_code: 401, response_body: response.body)
      when 404
        raise APIError.new("Not found", status_code: 404, response_body: response.body)
      when 422
        raise APIError.new("Unprocessable entity: #{response.body}", status_code: 422, response_body: response.body)
      when 429
        raise APIError.new("Rate limited", status_code: 429, response_body: response.body)
      when 500..599
        raise APIError.new("Server error", status_code: response.status, response_body: response.body)
      else
        raise APIError.new("Request failed", status_code: response.status, response_body: response.body)
      end
    end
  end
end
