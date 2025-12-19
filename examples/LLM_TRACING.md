# LLM Tracing Examples

This guide shows how to trace LLM calls with the LangSmith Ruby SDK, including token usage tracking, streaming, and multi-step chains.

## Table of Contents

- [Basic LLM Call with Token Usage](#basic-llm-call-with-token-usage)
- [Adding Metadata](#adding-metadata)
- [Streaming LLM Calls](#streaming-llm-calls)
- [Multi-Step Chains](#multi-step-chains)
- [Using the Traceable Module](#using-the-traceable-module)
- [OpenAI Integration](#openai-integration)
- [Anthropic Integration](#anthropic-integration)
- [Error Handling](#error-handling)
- [Multi-Tenant Tracing](#multi-tenant-tracing)

---

## Basic LLM Call with Token Usage

Track token usage from your LLM API responses:

```ruby
Langsmith.trace("openai_chat", run_type: "llm", inputs: { prompt: user_message }) do |run|
  response = openai_client.chat(
    parameters: {
      model: "gpt-4",
      messages: [{ role: "user", content: user_message }]
    }
  )

  # Set token usage from the API response
  run.set_token_usage(
    prompt_tokens: response["usage"]["prompt_tokens"],
    completion_tokens: response["usage"]["completion_tokens"],
    total_tokens: response["usage"]["total_tokens"]
  )

  response.dig("choices", 0, "message", "content")
end
```

---

## Adding Metadata

Enrich your traces with model configuration and response details:

```ruby
Langsmith.trace("llm_call", run_type: "llm") do |run|
  # Add request metadata
  run.add_metadata(
    model: "gpt-4",
    temperature: 0.7,
    max_tokens: 1000,
    provider: "openai"
  )

  response = call_llm(messages)

  # Add response metadata
  run.add_metadata(
    finish_reason: response.dig("choices", 0, "finish_reason"),
    response_id: response["id"],
    model_version: response["model"]
  )

  # Add tags for filtering in LangSmith UI
  run.add_tags("production", "gpt-4", "chat")

  response.dig("choices", 0, "message", "content")
end
```

---

## Streaming LLM Calls

For streaming responses, accumulate tokens and track chunks:

```ruby
Langsmith.trace("streaming_chat", run_type: "llm", inputs: { prompt: prompt }) do |run|
  run.add_metadata(model: "gpt-4", streaming: true)

  full_response = ""
  chunk_count = 0

  openai_client.chat(
    parameters: {
      model: "gpt-4",
      messages: [{ role: "user", content: prompt }],
      stream: proc do |chunk, _bytesize|
        content = chunk.dig("choices", 0, "delta", "content")
        if content
          full_response += content
          chunk_count += 1

          # Optionally track each chunk as an event
          run.add_event(name: "chunk", content_length: content.length)
        end
      end
    }
  )

  # Estimate tokens for streaming (OpenAI doesn't return usage for streams)
  run.set_token_usage(
    prompt_tokens: (prompt.length / 4.0).ceil,
    completion_tokens: (full_response.length / 4.0).ceil
  )

  run.add_metadata(chunk_count: chunk_count, response_length: full_response.length)

  full_response
end
```

---

## Multi-Step Chains

Trace complex workflows with nested calls:

```ruby
Langsmith.trace("rag_chain", run_type: "chain", inputs: { question: question }) do |chain|
  chain.add_metadata(chain_type: "retrieval_qa")
  chain.add_tags("rag", "production")

  # Step 1: Embed the question
  embedding = Langsmith.trace("embed_question", run_type: "llm") do |run|
    response = openai_client.embeddings(
      parameters: { model: "text-embedding-3-small", input: question }
    )

    run.set_token_usage(prompt_tokens: response["usage"]["prompt_tokens"], completion_tokens: 0)
    run.add_metadata(model: "text-embedding-3-small", dimensions: 1536)

    response.dig("data", 0, "embedding")
  end

  # Step 2: Retrieve relevant documents
  documents = Langsmith.trace("retrieve_docs", run_type: "retriever") do |run|
    run.add_metadata(index: "knowledge_base", top_k: 5)

    results = vector_store.similarity_search(embedding, limit: 5)

    run.add_metadata(results_count: results.length)
    results
  end

  # Step 3: Generate answer
  answer = Langsmith.trace("generate_answer", run_type: "llm") do |run|
    context = documents.map(&:content).join("\n\n")

    response = openai_client.chat(
      parameters: {
        model: "gpt-4",
        messages: [
          { role: "system", content: "Answer based on context:\n#{context}" },
          { role: "user", content: question }
        ]
      }
    )

    run.set_token_usage(
      prompt_tokens: response["usage"]["prompt_tokens"],
      completion_tokens: response["usage"]["completion_tokens"]
    )
    run.add_metadata(model: "gpt-4", context_docs: documents.length)

    response.dig("choices", 0, "message", "content")
  end

  answer
end
```

---

## Using the Traceable Module

Decorate methods for automatic tracing:

```ruby
class LLMService
  include Langsmith::Traceable

  def initialize(model: "gpt-4")
    @model = model
    @client = OpenAI::Client.new
  end

  traceable run_type: "llm", name: "llm_service.chat"
  def chat(messages, temperature: 0.7)
    response = @client.chat(
      parameters: {
        model: @model,
        messages: messages,
        temperature: temperature
      }
    )

    # Access current run to set token usage
    if (run = Langsmith.current_run)
      run.set_token_usage(
        prompt_tokens: response["usage"]["prompt_tokens"],
        completion_tokens: response["usage"]["completion_tokens"]
      )
      run.add_metadata(model: @model, temperature: temperature)
    end

    response.dig("choices", 0, "message", "content")
  end

  traceable run_type: "llm", name: "llm_service.embed"
  def embed(text)
    response = @client.embeddings(
      parameters: { model: "text-embedding-3-small", input: text }
    )

    Langsmith.current_run&.set_token_usage(
      prompt_tokens: response["usage"]["prompt_tokens"],
      completion_tokens: 0
    )

    response.dig("data", 0, "embedding")
  end
end

# Usage
service = LLMService.new(model: "gpt-4")
response = service.chat([{ role: "user", content: "Hello!" }])
```

---

## OpenAI Integration

Complete wrapper for the ruby-openai gem:

```ruby
require "openai"

module TracedOpenAI
  CLIENT = OpenAI::Client.new

  module_function

  def chat(messages:, model: "gpt-4", **options)
    Langsmith.trace("openai.chat", run_type: "llm", inputs: { messages: messages }) do |run|
      run.add_metadata(model: model, **options.slice(:temperature, :max_tokens))

      response = CLIENT.chat(
        parameters: { model: model, messages: messages, **options }
      )

      run.set_token_usage(
        prompt_tokens: response["usage"]["prompt_tokens"],
        completion_tokens: response["usage"]["completion_tokens"]
      )

      run.add_metadata(
        finish_reason: response.dig("choices", 0, "finish_reason"),
        response_id: response["id"]
      )

      response
    end
  end

  def embed(input:, model: "text-embedding-3-small")
    Langsmith.trace("openai.embed", run_type: "llm", inputs: { input: input }) do |run|
      run.add_metadata(model: model)

      response = CLIENT.embeddings(parameters: { model: model, input: input })

      run.set_token_usage(prompt_tokens: response["usage"]["prompt_tokens"], completion_tokens: 0)
      run.add_metadata(dimensions: response.dig("data", 0, "embedding")&.length)

      response
    end
  end
end

# Usage
response = TracedOpenAI.chat(
  messages: [{ role: "user", content: "What is Ruby?" }],
  model: "gpt-4",
  temperature: 0.7
)
```

---

## Anthropic Integration

Wrapper for the anthropic gem:

```ruby
require "anthropic"

module TracedAnthropic
  CLIENT = Anthropic::Client.new

  module_function

  def message(messages:, model: "claude-3-sonnet-20240229", max_tokens: 1024, **options)
    Langsmith.trace("anthropic.message", run_type: "llm", inputs: { messages: messages }) do |run|
      run.add_metadata(model: model, max_tokens: max_tokens, provider: "anthropic")

      response = CLIENT.messages(
        parameters: {
          model: model,
          messages: messages,
          max_tokens: max_tokens,
          **options
        }
      )

      # Anthropic returns usage differently
      run.set_token_usage(
        prompt_tokens: response["usage"]["input_tokens"],
        completion_tokens: response["usage"]["output_tokens"]
      )

      run.add_metadata(
        stop_reason: response["stop_reason"],
        response_id: response["id"]
      )

      response
    end
  end
end

# Usage
response = TracedAnthropic.message(
  messages: [{ role: "user", content: "Explain Ruby in one sentence." }],
  model: "claude-3-sonnet-20240229"
)
```

---

## Error Handling

Track errors and retries in your traces:

```ruby
Langsmith.trace("llm_with_retry", run_type: "llm", inputs: { prompt: prompt }) do |run|
  run.add_metadata(max_retries: 3)

  retries = 0
  begin
    response = call_llm(prompt)

    run.set_token_usage(
      prompt_tokens: response["usage"]["prompt_tokens"],
      completion_tokens: response["usage"]["completion_tokens"]
    )
    run.add_metadata(retries: retries, success: true)

    response.dig("choices", 0, "message", "content")

  rescue RateLimitError => e
    retries += 1
    run.add_event(name: "retry", attempt: retries, reason: "rate_limit", wait: 2**retries)

    if retries <= 3
      sleep(2**retries)
      retry
    end

    run.add_metadata(success: false, final_error: e.message)
    raise

  rescue APIError => e
    run.add_event(name: "error", type: e.class.name, message: e.message)
    run.add_metadata(success: false, error_type: e.class.name)
    raise
  end
end
```

---

## Multi-Tenant Tracing

Route traces to different tenants:

```ruby
# Global default tenant
Langsmith.configure do |config|
  config.tenant_id = "default-tenant"
end

# Per-request tenant override
def process_customer_request(customer_id, prompt)
  tenant_id = "customer-#{customer_id}"

  Langsmith.trace("customer_llm_call", run_type: "llm", tenant_id: tenant_id) do |run|
    run.add_metadata(customer_id: customer_id)

    response = call_llm(prompt)

    run.set_token_usage(
      prompt_tokens: response["usage"]["prompt_tokens"],
      completion_tokens: response["usage"]["completion_tokens"]
    )

    response.dig("choices", 0, "message", "content")
  end
end

# Nested traces inherit tenant_id
Langsmith.trace("parent", tenant_id: "tenant-123") do
  Langsmith.trace("child") do |run|
    # This trace also goes to tenant-123
    run.add_metadata(inherited_tenant: true)
  end
end
```

---

## Best Practices

1. **Always set token usage** - It enables cost tracking in LangSmith
2. **Add model metadata** - Include model name, temperature, and other parameters
3. **Use meaningful names** - Name your traces descriptively (e.g., `"generate_summary"` not `"llm_call"`)
4. **Track finish reasons** - Helps identify truncated responses
5. **Use events for streaming** - Track chunk counts and timing
6. **Handle errors gracefully** - Add error events before re-raising
7. **Flush before exit** - Call `Langsmith.shutdown` to ensure all traces are sent

```ruby
# At application shutdown
at_exit { Langsmith.shutdown }
```

