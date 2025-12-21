# LangSmith Ruby SDK

A Ruby SDK for [LangSmith](https://smith.langchain.com/) tracing and observability.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'langsmith-sdk'
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install langsmith-sdk
```

## Configuration

Set up your LangSmith credentials via environment variables:

```bash
export LANGSMITH_API_KEY=ls_...
export LANGSMITH_TRACING=true
export LANGSMITH_PROJECT=my-project   # optional, defaults to "default"
export LANGSMITH_TENANT_ID=tenant-123 # optional, for multi-tenant scenarios
```

Or configure programmatically:

```ruby
Langsmith.configure do |config|
  config.api_key = "ls_..."
  config.tracing_enabled = true
  config.project = "my-project"
  config.tenant_id = "tenant-123" # optional, for multi-tenant scenarios
end
```

## Usage

### Block-based Tracing

```ruby
require "langsmith"

result = Langsmith.trace("my_operation", run_type: "chain") do |run|
  run.add_metadata(user_id: "123")

  # Your code here
  response = call_llm(prompt)

  response
end
```

### Nested Traces

Traces automatically nest when called within other traces:

```ruby
Langsmith.trace("parent_chain", run_type: "chain") do
  # This will be a child of parent_chain
  Langsmith.trace("child_llm_call", run_type: "llm") do
    call_openai(prompt)
  end

  # Another child
  Langsmith.trace("child_tool", run_type: "tool") do
    search_database(query)
  end
end
```

### Method Decoration with Traceable

```ruby
class MyService
  include Langsmith::Traceable

  traceable run_type: "chain"
  def process(input)
    # This method is automatically traced
    transform(input)
  end

  traceable run_type: "llm", name: "openai_call"
  def call_llm(prompt)
    # Traced with custom name
    client.chat(prompt)
  end
end
```

## Run Types

Supported run types:
- `"chain"` - A sequence of operations
- `"llm"` - LLM API calls
- `"tool"` - Tool/function executions
- `"retriever"` - Document retrieval operations
- `"prompt"` - Prompt template rendering
- `"parser"` - Output parsing operations

## Per-Trace Project Override

You can override the project for specific traces at runtime:

```ruby
# Override project for a specific trace (and its children)
Langsmith.trace("operation", project: "my-special-project") do
  # This trace goes to "my-special-project"

  # Nested traces inherit project from parent automatically
  Langsmith.trace("child") do
    # Also goes to "my-special-project"
  end
end
```


## Multi-Tenant Support

For multi-tenant scenarios, you can set a global tenant ID or override it per-trace:

### Global Configuration

```ruby
Langsmith.configure do |config|
  config.tenant_id = "tenant-123"
end

# All traces will use tenant-123
Langsmith.trace("operation") do
  # ...
end
```

### Per-Trace Override

```ruby
# Override tenant for a specific trace (and its children)
Langsmith.trace("operation", tenant_id: "tenant-456") do
  # This trace goes to tenant-456

  # Nested traces inherit tenant_id from parent
  Langsmith.trace("child") do
    # Also goes to tenant-456
  end
end
```

### With Traceable Module

```ruby
class MultiTenantService
  include Langsmith::Traceable

  traceable run_type: "chain", tenant_id: "tenant-123"
  def process_for_tenant_123(data)
    # Always traced to tenant-123
  end

  traceable run_type: "chain", tenant_id: "tenant-456"
  def process_for_tenant_456(data)
    # Always traced to tenant-456
  end
end
```

The SDK automatically batches traces by tenant ID, so traces for different tenants are sent in separate API requests with the appropriate `X-Tenant-Id` header.

## Token Usage Tracking

Track token usage for LLM calls:

```ruby
Langsmith.trace("openai_call", run_type: "llm") do |run|
  response = openai_client.chat(parameters: { model: "gpt-4", messages: messages })

  # Set model info (displayed in LangSmith UI)
  run.set_model(model: "gpt-4", provider: "openai")

  # Set token usage from API response
  run.set_token_usage(
    input_tokens: response["usage"]["prompt_tokens"],
    output_tokens: response["usage"]["completion_tokens"],
    total_tokens: response["usage"]["total_tokens"]
  )

  # Add additional metadata
  run.add_metadata(finish_reason: response.dig("choices", 0, "finish_reason"))

  response.dig("choices", 0, "message", "content")
end
```

## Examples

See [`examples/LLM_TRACING.md`](examples/LLM_TRACING.md) for comprehensive examples including:

- Basic LLM calls with token usage
- Streaming responses
- Multi-step chains (RAG)
- OpenAI and Anthropic integrations
- Error handling and retries
- Multi-tenant tracing
- Per-trace project overrides

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `bundle exec rspec` to run the tests.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

