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

    private

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
