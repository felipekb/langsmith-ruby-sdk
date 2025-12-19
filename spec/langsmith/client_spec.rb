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
