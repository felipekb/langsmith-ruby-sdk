# frozen_string_literal: true

RSpec.describe Langsmith::Client do
  let(:api_key) { "test_api_key" }
  let(:endpoint) { "https://api.smith.langchain.com" }
  let(:client) { described_class.new(api_key: api_key, endpoint: endpoint) }

  before do
    Langsmith.configure do |config|
      config.api_key = api_key
      config.endpoint = endpoint
    end
  end

  describe "#create_run" do
    let(:run) { Langsmith::Run.new(name: "test_run") }

    it "sends POST request to /runs" do
      stub = stub_request(:post, "#{endpoint}/runs")
             .with(
               headers: {
                 "Content-Type" => "application/json",
                 "X-API-Key" => api_key
               }
             )
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      client.create_run(run)

      expect(stub).to have_been_requested
    end

    it "includes run data in request body" do
      stub = stub_request(:post, "#{endpoint}/runs")
             .with do |request|
        body = JSON.parse(request.body, symbolize_names: true)
        body[:name] == "test_run" && body[:run_type] == "chain"
      end
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      client.create_run(run)

      expect(stub).to have_been_requested
    end
  end

  describe "#update_run" do
    let(:run) { Langsmith::Run.new(name: "test_run") }

    it "sends PATCH request to /runs/:id" do
      stub = stub_request(:patch, "#{endpoint}/runs/#{run.id}")
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      client.update_run(run)

      expect(stub).to have_been_requested
    end
  end

  describe "#batch_ingest" do
    let(:run1) { Langsmith::Run.new(name: "run1") }
    let(:run2) { Langsmith::Run.new(name: "run2") }

    it "sends POST request to /runs/batch" do
      stub = stub_request(:post, "#{endpoint}/runs/batch")
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      client.batch_ingest(post_runs: [run1], patch_runs: [run2])

      expect(stub).to have_been_requested
    end

    it "includes post and patch arrays in body" do
      stub = stub_request(:post, "#{endpoint}/runs/batch")
             .with do |request|
        body = JSON.parse(request.body, symbolize_names: true)
        body[:post].length == 1 && body[:patch].length == 1
      end
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      client.batch_ingest(post_runs: [run1], patch_runs: [run2])

      expect(stub).to have_been_requested
    end

    it "skips request when both arrays are empty" do
      stub = stub_request(:post, "#{endpoint}/runs/batch")

      client.batch_ingest(post_runs: [], patch_runs: [])

      expect(stub).not_to have_been_requested
    end
  end

  describe "GET error handling" do
    let(:json_headers) { { "Content-Type" => "application/json" } }
    let(:examples_query) { { dataset: "ds-123" } }

    it "raises APIError on 401" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: examples_query)
        .to_return(status: 401, body: '{"error": "Unauthorized"}', headers: json_headers)

      expect { client.list_examples(dataset_id: "ds-123") }
        .to raise_error(Langsmith::Client::APIError) do |error|
          expect(error.status_code).to eq(401)
          expect(error.message).to include("Unauthorized")
        end
    end

    it "raises APIError on 404" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: examples_query)
        .to_return(status: 404, body: '{"error": "Not found"}', headers: json_headers)

      expect { client.list_examples(dataset_id: "ds-123") }
        .to raise_error(Langsmith::Client::APIError) { |e| expect(e.status_code).to eq(404) }
    end

    it "raises APIError on 429" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: examples_query)
        .to_return(status: 429, body: '{"error": "Rate limited"}', headers: json_headers)

      expect { client.list_examples(dataset_id: "ds-123") }
        .to raise_error(Langsmith::Client::APIError) do |error|
          expect(error.status_code).to eq(429)
          expect(error.message).to include("Rate limited")
        end
    end

    it "raises APIError on 500" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: examples_query)
        .to_return(status: 500, body: '{"error": "Server"}', headers: json_headers)

      expect { client.list_examples(dataset_id: "ds-123") }
        .to raise_error(Langsmith::Client::APIError) { |e| expect(e.status_code).to eq(500) }
    end

    it "raises APIError on connection failure" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: examples_query)
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      expect { client.list_examples(dataset_id: "ds-123") }
        .to raise_error(Langsmith::Client::APIError) { |e| expect(e.message).to include("Network error") }
    end

    it "raises APIError on timeout" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: examples_query)
        .to_timeout

      expect { client.list_examples(dataset_id: "ds-123") }
        .to raise_error(Langsmith::Client::APIError) { |e| expect(e.message).to include("Network error") }
    end
  end

  describe "#list_examples" do
    let(:tenant_id) { "test-tenant-id" }
    let(:examples_body) do
      [
        { id: "ex-1", dataset_id: "ds-123", inputs: { text: "hello" }, outputs: { label: "greeting" } },
        { id: "ex-2", dataset_id: "ds-123", inputs: { text: "bye" }, outputs: { label: "farewell" } }
      ].to_json
    end

    it "sends GET to /api/v1/examples with dataset query param" do
      stub = stub_request(:get, "#{endpoint}/api/v1/examples")
             .with(query: { dataset: "ds-123" })
             .to_return(status: 200, body: examples_body, headers: { "Content-Type" => "application/json" })

      result = client.list_examples(dataset_id: "ds-123", tenant_id: tenant_id)

      expect(stub).to have_been_requested
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end

    it "includes tenant_id header" do
      stub = stub_request(:get, "#{endpoint}/api/v1/examples")
             .with(query: { dataset: "ds-123" }, headers: { "X-Tenant-Id" => tenant_id })
             .to_return(status: 200, body: examples_body, headers: { "Content-Type" => "application/json" })

      client.list_examples(dataset_id: "ds-123", tenant_id: tenant_id)

      expect(stub).to have_been_requested
    end

    it "returns example objects with expected fields" do
      stub_request(:get, "#{endpoint}/api/v1/examples")
        .with(query: { dataset: "ds-123" })
        .to_return(status: 200, body: examples_body, headers: { "Content-Type" => "application/json" })

      result = client.list_examples(dataset_id: "ds-123", tenant_id: tenant_id)

      expect(result.first[:id]).to eq("ex-1")
      expect(result.first[:inputs]).to eq({ text: "hello" })
      expect(result.first[:outputs]).to eq({ label: "greeting" })
    end

    it "forwards limit and offset query params" do
      stub = stub_request(:get, "#{endpoint}/api/v1/examples")
             .with(query: { dataset: "ds-123", limit: "10", offset: "20" })
             .to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

      client.list_examples(dataset_id: "ds-123", limit: 10, offset: 20, tenant_id: tenant_id)

      expect(stub).to have_been_requested
    end

    it "falls back to configured tenant_id when not provided" do
      Langsmith.configuration.tenant_id = "configured-tenant"

      stub = stub_request(:get, "#{endpoint}/api/v1/examples")
             .with(query: { dataset: "ds-123" }, headers: { "X-Tenant-Id" => "configured-tenant" })
             .to_return(status: 200, body: examples_body, headers: { "Content-Type" => "application/json" })

      client.list_examples(dataset_id: "ds-123")

      expect(stub).to have_been_requested
    end

    it "prefers explicit tenant_id over configured one" do
      Langsmith.configuration.tenant_id = "configured-tenant"

      stub = stub_request(:get, "#{endpoint}/api/v1/examples")
             .with(query: { dataset: "ds-123" }, headers: { "X-Tenant-Id" => "explicit-tenant" })
             .to_return(status: 200, body: examples_body, headers: { "Content-Type" => "application/json" })

      client.list_examples(dataset_id: "ds-123", tenant_id: "explicit-tenant")

      expect(stub).to have_been_requested
    end
  end

  describe "#create_experiment" do
    let(:tenant_id) { "test-tenant-id" }
    let(:session_body) { { id: "session-xyz-789", name: "my-experiment" }.to_json }

    it "sends POST to /api/v1/sessions with correct payload" do
      stub = stub_request(:post, "#{endpoint}/api/v1/sessions")
             .with do |request|
               body = JSON.parse(request.body, symbolize_names: true)
               body[:name] == "my-experiment" &&
                 body[:reference_dataset_id] == "ds-123" &&
                 body[:description] == "Test experiment" &&
                 body[:extra] == { version: "1.0" }
             end
             .to_return(status: 200, body: session_body, headers: { "Content-Type" => "application/json" })

      result = client.create_experiment(
        name: "my-experiment", dataset_id: "ds-123",
        description: "Test experiment", metadata: { version: "1.0" }, tenant_id: tenant_id
      )

      expect(stub).to have_been_requested
      expect(result[:id]).to eq("session-xyz-789")
    end

    it "includes tenant_id header" do
      stub = stub_request(:post, "#{endpoint}/api/v1/sessions")
             .with(headers: { "X-Tenant-Id" => tenant_id })
             .to_return(status: 200, body: session_body, headers: { "Content-Type" => "application/json" })

      client.create_experiment(name: "my-experiment", dataset_id: "ds-123", tenant_id: tenant_id)

      expect(stub).to have_been_requested
    end

    it "sends only provided fields and defaults start_time" do
      stub = stub_request(:post, "#{endpoint}/api/v1/sessions")
             .with do |request|
               body = JSON.parse(request.body, symbolize_names: true)
               body[:name] == "my-experiment" && body[:reference_dataset_id] == "ds-123" &&
                 !body.key?(:description) && !body.key?(:extra) && body.key?(:start_time)
             end
             .to_return(status: 200, body: session_body, headers: { "Content-Type" => "application/json" })

      client.create_experiment(name: "my-experiment", dataset_id: "ds-123", tenant_id: tenant_id)

      expect(stub).to have_been_requested
    end

    it "includes start_time as ISO-8601 string" do
      frozen_time = Time.utc(2026, 2, 10, 12, 0, 0)
      allow(Time).to receive(:now).and_return(frozen_time)

      stub = stub_request(:post, "#{endpoint}/api/v1/sessions")
             .with do |request|
               body = JSON.parse(request.body, symbolize_names: true)
               body[:start_time] == "2026-02-10T12:00:00Z"
             end
             .to_return(status: 200, body: session_body, headers: { "Content-Type" => "application/json" })

      client.create_experiment(name: "my-experiment", dataset_id: "ds-123", tenant_id: tenant_id)

      expect(stub).to have_been_requested
    end
  end

  describe "#close_experiment" do
    let(:tenant_id) { "test-tenant-id" }
    let(:close_body) { { id: "session-xyz-789", end_time: "2026-02-10T12:00:00Z" }.to_json }

    it "sends PATCH to /api/v1/sessions/:id with end_time" do
      stub = stub_request(:patch, "#{endpoint}/api/v1/sessions/session-xyz-789")
             .with do |request|
               body = JSON.parse(request.body, symbolize_names: true)
               body[:end_time] == "2026-02-10T12:00:00Z"
             end
             .to_return(status: 200, body: close_body, headers: { "Content-Type" => "application/json" })

      result = client.close_experiment(
        experiment_id: "session-xyz-789", end_time: "2026-02-10T12:00:00Z", tenant_id: tenant_id
      )

      expect(stub).to have_been_requested
      expect(result[:end_time]).to eq("2026-02-10T12:00:00Z")
    end

    it "includes tenant_id header" do
      stub = stub_request(:patch, "#{endpoint}/api/v1/sessions/session-xyz-789")
             .with(headers: { "X-Tenant-Id" => tenant_id })
             .to_return(status: 200, body: close_body, headers: { "Content-Type" => "application/json" })

      client.close_experiment(
        experiment_id: "session-xyz-789", end_time: "2026-02-10T12:00:00Z", tenant_id: tenant_id
      )

      expect(stub).to have_been_requested
    end
  end

  describe "error handling" do
    let(:run) { Langsmith::Run.new(name: "test_run") }

    it "raises APIError on 401" do
      stub_request(:post, "#{endpoint}/runs")
        .to_return(status: 401, body: '{"error": "Unauthorized"}', headers: { "Content-Type" => "application/json" })

      expect { client.create_run(run) }.to raise_error(Langsmith::Client::APIError) do |error|
        expect(error.status_code).to eq(401)
        expect(error.message).to include("Unauthorized")
      end
    end

    it "raises APIError on 500" do
      stub_request(:post, "#{endpoint}/runs")
        .to_return(
          status: 500,
          body: '{"error": "Internal Server Error"}',
          headers: { "Content-Type" => "application/json" }
        )

      expect { client.create_run(run) }.to raise_error(Langsmith::Client::APIError) do |error|
        expect(error.status_code).to eq(500)
      end
    end

    it "raises APIError on connection failure" do
      stub_request(:post, "#{endpoint}/runs")
        .to_raise(Faraday::ConnectionFailed.new("Connection refused"))

      expect { client.create_run(run) }.to raise_error(Langsmith::Client::APIError) do |error|
        expect(error.message).to include("Network error")
      end
    end

    it "raises APIError on timeout" do
      stub_request(:post, "#{endpoint}/runs")
        .to_timeout

      expect { client.create_run(run) }.to raise_error(Langsmith::Client::APIError) do |error|
        expect(error.message).to include("Network error")
      end
    end
  end
end
