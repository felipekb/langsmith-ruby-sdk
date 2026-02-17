# LangSmith Ruby SDK

A Ruby SDK for [LangSmith](https://smith.langchain.com/) tracing, experiments, and evaluations.

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

## Evaluations (Datasets + Experiments)

Run your app against a LangSmith dataset and attach evaluator feedback to each traced example run:

```ruby
require "langsmith"

summary = Langsmith::Evaluation.run(
  dataset_id: "dataset-uuid",
  experiment_name: "qa-baseline-v1",
  description: "First baseline on FAQ dataset",
  metadata: { model: "gpt-4", prompt_version: 3 },
  evaluators: {
    correctness: lambda { |outputs:, reference_outputs:, inputs:, run:|
      predicted = outputs[:answer].to_s.strip.downcase
      expected = reference_outputs[:answer].to_s.strip.downcase

      {
        score: predicted == expected ? 1.0 : 0.0,
        value: predicted,
        comment: "question=#{inputs[:question]} run_id=#{run[:id]}"
      }
    },
    has_answer: ->(outputs:, **) { outputs[:answer].to_s.empty? ? 0.0 : 1.0 }
  }
) do |example|
  # Wrap each dataset example in a trace so feedback can attach to the run.
  Langsmith.trace("qa_inference", run_type: "chain", inputs: example[:inputs]) do
    answer = MyApp.answer(example[:inputs][:question])
    { answer: answer }
  end
end

pp summary
```

### Evaluator Contract

Each evaluator receives keyword arguments:
- `outputs:` your block return value
- `reference_outputs:` `example[:outputs]` from the dataset
- `inputs:` `example[:inputs]` from the dataset
- `run:` the LangSmith run hash for the traced example

Evaluator return values:
- `Numeric` -> used as `score`
- `true` / `false` -> converted to `1.0` / `0.0`
- `Hash` -> expected keys: `:score`, `:value`, `:comment`
- `nil` -> skip feedback creation for that evaluator

If one evaluator raises, the others still run. If your example block raises, the example is marked failed and the experiment continues.

### Evaluation Summary

`Langsmith::Evaluation.run` returns:
- `:experiment_id`
- `:total`
- `:succeeded`
- `:failed`
- `:results` (per-example `:example_id`, `:run_id`, `:status`, `:error`, `:feedback`)

## Examples

See [`examples/LLM_TRACING.md`](examples/LLM_TRACING.md) for comprehensive examples including:

- Basic LLM calls with token usage
- Streaming responses
- Multi-step chains (RAG)
- OpenAI and Anthropic integrations
- Error handling and retries
- Multi-tenant tracing
- Per-trace project overrides
- Dataset experiments and evaluations (see section above)

## Development

After checking out the repo, run `bundle install` to install dependencies. Then, run `bundle exec rspec` to run the tests.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
