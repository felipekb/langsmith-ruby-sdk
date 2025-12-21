# frozen_string_literal: true

# Example: Integration with ruby-openai gem
#
# This example shows how to integrate LangSmith tracing with the ruby-openai gem.
# Install: gem install ruby-openai
#
# Run with: OPENAI_API_KEY=sk-... LANGSMITH_API_KEY=ls_... ruby examples/openai_integration.rb

require_relative "../lib/langsmith"

begin
  require "openai"
  require "json"
rescue LoadError
  puts "This example requires the ruby-openai gem."
  puts "Install with: gem install ruby-openai"
  exit 1
end

# Configure Langsmith
Langsmith.configure do |config|
  config.api_key = ENV.fetch("LANGSMITH_API_KEY")
  config.tracing_enabled = true
  config.project = "openai-ruby-examples"
end

# Create OpenAI client
OPENAI_CLIENT = OpenAI::Client.new(access_token: ENV.fetch("OPENAI_API_KEY"))

# Wrapper for traced OpenAI chat completions
module TracedOpenAI
  module_function

  # Traced chat completion
  def chat(messages:, model: "gpt-4o-mini", temperature: 0.7, **options)
    Langsmith.trace(
      "openai.chat.completions",
      run_type: "llm",
      inputs: { messages: messages, model: model, temperature: temperature }
    ) do |run|
      # Set model for LangSmith to display
      run.set_model(model: model, provider: "openai")

      # Add request metadata
      run.add_metadata(
        temperature: temperature,
        **options.slice(:max_tokens, :top_p, :frequency_penalty, :presence_penalty)
      )

      # Make the actual API call
      response = OPENAI_CLIENT.chat(
        parameters: {
          model: model,
          messages: messages,
          temperature: temperature,
          **options
        }
      )

      # Extract and set token usage (Python SDK uses input_tokens/output_tokens)
      if response["usage"]
        run.set_token_usage(
          input_tokens: response["usage"]["prompt_tokens"],
          output_tokens: response["usage"]["completion_tokens"],
          total_tokens: response["usage"]["total_tokens"]
        )
      end

      # Add response metadata
      run.add_metadata(
        response_id: response["id"],
        finish_reason: response.dig("choices", 0, "finish_reason")
      )

      # Return the response
      response
    end
  end

  # Traced embedding
  def embed(input:, model: "text-embedding-3-small")
    Langsmith.trace(
      "openai.embeddings",
      run_type: "llm",
      inputs: { input: input, model: model }
    ) do |run|
      run.set_model(model: model, provider: "openai")

      response = OPENAI_CLIENT.embeddings(
        parameters: { model: model, input: input }
      )

      # Set token usage for embeddings (no output tokens)
      if response["usage"]
        run.set_token_usage(
          input_tokens: response["usage"]["prompt_tokens"],
          total_tokens: response["usage"]["total_tokens"]
        )
      end

      run.add_metadata(
        dimensions: response.dig("data", 0, "embedding")&.length,
        input_count: Array(input).length
      )

      response
    end
  end

  # Traced structured output with JSON schema
  # Uses OpenAI's response_format for guaranteed structured responses
  def structured_output(messages:, schema:, schema_name: "response", model: "gpt-4o-mini", **options)
    Langsmith.trace(
      "openai.chat.structured",
      run_type: "llm",
      inputs: {
        messages: messages,
        model: model,
        schema_name: schema_name,
        schema: schema
      }
    ) do |run|
      run.set_model(model: model, provider: "openai")
      run.add_metadata(structured_output: true, schema_name: schema_name)
      run.add_tags("structured-output", "json-schema")

      # Build the response_format for structured outputs
      response_format = {
        type: "json_schema",
        json_schema: {
          name: schema_name,
          strict: true,
          schema: schema
        }
      }

      response = OPENAI_CLIENT.chat(
        parameters: {
          model: model,
          messages: messages,
          response_format: response_format,
          **options
        }
      )

      # Extract and set token usage
      if response["usage"]
        run.set_token_usage(
          input_tokens: response["usage"]["prompt_tokens"],
          output_tokens: response["usage"]["completion_tokens"],
          total_tokens: response["usage"]["total_tokens"]
        )
      end

      # Parse the structured response
      content = response.dig("choices", 0, "message", "content")
      parsed = JSON.parse(content, symbolize_names: true)

      run.add_metadata(
        response_id: response["id"],
        finish_reason: response.dig("choices", 0, "finish_reason")
      )

      # Return just the parsed result (cleaner output)
      parsed
    end
  end

  # Traced function calling (tools)
  def function_call(messages:, tools:, model: "gpt-4o-mini", tool_choice: "auto", **options)
    Langsmith.trace(
      "openai.chat.function_call",
      run_type: "llm",
      inputs: {
        messages: messages,
        model: model,
        tools: tools.map { |t| t[:function][:name] }
      }
    ) do |run|
      run.set_model(model: model, provider: "openai")
      run.add_metadata(
        tool_choice: tool_choice,
        available_tools: tools.map { |t| t[:function][:name] }
      )
      run.add_tags("function-calling", "tools")

      response = OPENAI_CLIENT.chat(
        parameters: {
          model: model,
          messages: messages,
          tools: tools,
          tool_choice: tool_choice,
          **options
        }
      )

      if response["usage"]
        run.set_token_usage(
          input_tokens: response["usage"]["prompt_tokens"],
          output_tokens: response["usage"]["completion_tokens"],
          total_tokens: response["usage"]["total_tokens"]
        )
      end

      # Extract tool calls if any
      tool_calls = response.dig("choices", 0, "message", "tool_calls") || []
      parsed_tool_calls = tool_calls.map do |tc|
        {
          id: tc["id"],
          function: tc["function"]["name"],
          arguments: JSON.parse(tc["function"]["arguments"], symbolize_names: true)
        }
      end

      run.add_metadata(
        response_id: response["id"],
        finish_reason: response.dig("choices", 0, "finish_reason"),
        tool_calls_count: parsed_tool_calls.length
      )

      # Return just the tool calls (cleaner output)
      parsed_tool_calls
    end
  end

  # ============================================================================
  # OpenAI Responses API (new agent-focused API)
  # ============================================================================

  # Traced Responses API call - OpenAI's new simplified API for agents
  def responses(input:, model: "gpt-4o-mini", instructions: nil, tools: nil, **options)
    Langsmith.trace(
      "openai.responses",
      run_type: "llm",
      inputs: { input: input, model: model, instructions: instructions&.slice(0, 200) }
    ) do |run|
      run.set_model(model: model, provider: "openai")
      run.add_metadata(api: "responses")
      run.add_tags("responses-api")

      params = {
        model: model,
        input: input,
        **options
      }
      params[:instructions] = instructions if instructions
      params[:tools] = tools if tools

      response = OPENAI_CLIENT.responses.create(parameters: params)

      # Extract token usage from Responses API format (uses input_tokens/output_tokens)
      if response["usage"]
        run.set_token_usage(
          input_tokens: response["usage"]["input_tokens"],
          output_tokens: response["usage"]["output_tokens"],
          total_tokens: response["usage"]["total_tokens"]
        )
      end

      # Extract the output text
      output_text = response.dig("output", 0, "content", 0, "text") ||
                    response.dig("output_text") ||
                    response["output"]

      run.add_metadata(
        response_id: response["id"],
        status: response["status"]
      )

      # Return just the output text (cleaner output)
      output_text
    end
  end

  # Traced Responses API with tool use
  def responses_with_tools(input:, tools:, model: "gpt-4o-mini", instructions: nil, **options)
    Langsmith.trace(
      "openai.responses.with_tools",
      run_type: "chain",
      inputs: { input: input, tools: tools.map { |t| t[:name] } }
    ) do |run|
      run.add_metadata(
        api: "responses",
        tool_count: tools.length
      )
      run.add_tags("responses-api", "tools")

      # Initial response
      response = Langsmith.trace("responses.initial", run_type: "llm") do |llm_run|
        llm_run.set_model(model: model, provider: "openai")

        result = OPENAI_CLIENT.responses.create(
          parameters: {
            model: model,
            input: input,
            instructions: instructions,
            tools: tools,
            **options
          }
        )

        # Responses API uses input_tokens/output_tokens
        if result["usage"]
          llm_run.set_token_usage(
            input_tokens: result["usage"]["input_tokens"],
            output_tokens: result["usage"]["output_tokens"],
            total_tokens: result["usage"]["total_tokens"]
          )
        end

        result
      end

      # Check for tool calls in output
      tool_calls = []
      outputs = response["output"] || []
      outputs.each do |output|
        next unless output["type"] == "function_call"

        tool_calls << {
          id: output["call_id"],
          name: output["name"],
          arguments: JSON.parse(output["arguments"], symbolize_names: true)
        }
      end

      run.add_metadata(
        tool_calls_count: tool_calls.length
      )

      # Return just the tool calls (cleaner output)
      tool_calls
    end
  end

  # Traced streaming chat completion with TTFT (time to first token) tracking
  # Follows Python SDK pattern: adds "new_token" event for first token
  def chat_stream(messages:, model: "gpt-4o-mini", temperature: 0.7, &block)
    Langsmith.trace(
      "openai.chat.completions.stream",
      run_type: "llm",
      inputs: { messages: messages, model: model, streaming: true }
    ) do |run|
      run.set_model(model: model, provider: "openai")
      run.add_metadata(temperature: temperature, streaming: true)

      full_content = ""
      finish_reason = nil
      first_token_logged = false
      first_token_time = nil
      stream_start_time = Time.now

      OPENAI_CLIENT.chat(
        parameters: {
          model: model,
          messages: messages,
          temperature: temperature,
          stream: proc do |chunk, _bytesize|
            delta = chunk.dig("choices", 0, "delta", "content")
            if delta
              # Log "new_token" event for first token (Python SDK pattern)
              # LangSmith uses this to calculate time-to-first-token
              unless first_token_logged
                first_token_time = Time.now.utc
                run.add_event(name: "new_token", time: first_token_time, token: delta)
                first_token_logged = true
              end

              full_content += delta
              block&.call(delta)
            end

            # Capture finish reason from final chunk
            if (fr = chunk.dig("choices", 0, "finish_reason"))
              finish_reason = fr
            end
          end
        }
      )

      stream_end_time = Time.now

      # Calculate TTFT for display
      time_to_first_token = first_token_time ? (first_token_time - stream_start_time) : nil

      # Estimate tokens for streaming (OpenAI doesn't return usage for streams)
      estimated_input_tokens = messages.sum { |m| (m[:content].to_s.length / 4.0).ceil }
      estimated_output_tokens = (full_content.length / 4.0).ceil

      # Calculate tokens per second
      generation_time = first_token_time ? (stream_end_time - first_token_time) : (stream_end_time - stream_start_time)
      tokens_per_second = generation_time.positive? ? (estimated_output_tokens / generation_time).round(2) : nil

      run.set_token_usage(
        input_tokens: estimated_input_tokens,
        output_tokens: estimated_output_tokens,
        total_tokens: estimated_input_tokens + estimated_output_tokens
      )

      run.add_metadata(
        finish_reason: finish_reason,
        response_length: full_content.length,
        tokens_per_second: tokens_per_second
      )

      {
        content: full_content,
        finish_reason: finish_reason,
        time_to_first_token: time_to_first_token&.round(3),
        tokens_per_second: tokens_per_second
      }
    end
  end
end

# Example: RAG chain with OpenAI
class RAGChain
  def initialize(knowledge_base:)
    @knowledge_base = knowledge_base
  end

  def answer(question)
    Langsmith.trace("rag_chain", run_type: "chain", inputs: { question: question }) do
      question_embedding = embed_query(question)

      context = retrieve_context(question_embedding)

      generate_answer(question, context)
    end
  end

  private

  def embed_query(text)
    Langsmith.trace("embed_query", run_type: "llm", inputs: { text: text[0..50] }) do
      response = TracedOpenAI.embed(input: text)
      response.dig("data", 0, "embedding")
    end
  end

  def retrieve_context(embedding)
    Langsmith.trace("retrieve_context", run_type: "retriever", inputs: { top_k: 3 }) do |run|
      run.add_metadata(index: "knowledge_base", top_k: 3)
      @knowledge_base.first(3)
    end
  end

  def generate_answer(question, context)
    Langsmith.trace("generate_answer", run_type: "llm", inputs: { question: question }) do
      messages = [
        {
          role: "system",
          content: "Answer the question based on the following context:\n\n#{context.join("\n\n")}"
        },
        { role: "user", content: question }
      ]

      response = TracedOpenAI.chat(messages: messages, model: "gpt-4o-mini")
      response.dig("choices", 0, "message", "content")
    end
  end
end

# ============================================================================
# Run the examples
# ============================================================================

if __FILE__ == $PROGRAM_NAME
  puts "=" * 60
  puts "LangSmith + OpenAI Integration Examples"
  puts "=" * 60

  # Example 1: Simple chat
  puts "\n1. Simple chat completion:"
  response = TracedOpenAI.chat(
    messages: [{ role: "user", content: "What is Ruby programming language? Be brief." }],
    model: "gpt-3.5-turbo",
    max_tokens: 100
  )
  puts "   Response: #{response.dig("choices", 0, "message", "content")}"
  puts "   Tokens: #{response.dig("usage", "total_tokens")}"

  # Example 2: Embeddings
  puts "\n2. Text embeddings:"
  response = TracedOpenAI.embed(input: "Hello, world!")
  puts "   Embedding dimensions: #{response.dig("data", 0, "embedding")&.length}"
  puts "   Tokens used: #{response.dig("usage", "prompt_tokens")}"

  # Example 3: Streaming
  puts "\n3. Streaming chat:"
  print "   Response: "
  result = TracedOpenAI.chat_stream(
    messages: [{ role: "user", content: "Count from 1 to 5." }],
    model: "gpt-3.5-turbo"
  ) do |chunk|
    print chunk
  end
  puts "\n   Finish reason: #{result[:finish_reason]}"
  puts "   Time to first token: #{result[:time_to_first_token]}s"
  puts "   Tokens/sec: #{result[:tokens_per_second]}"

  # Example 4: Structured output - Entity extraction
  puts "\n4. Structured output (entity extraction):"
  # Note: OpenAI strict mode requires ALL properties to be in `required`
  entity_schema = {
    type: "object",
    properties: {
      people: {
        type: "array",
        items: {
          type: "object",
          properties: {
            name: { type: "string", description: "Person's full name" },
            role: { type: ["string", "null"], description: "Their role or title, null if unknown" },
            organization: { type: ["string", "null"], description: "Organization, null if unknown" }
          },
          required: %w[name role organization],
          additionalProperties: false
        }
      },
      locations: {
        type: "array",
        items: { type: "string" }
      },
      summary: { type: "string", description: "Brief summary of the text" }
    },
    required: %w[people locations summary],
    additionalProperties: false
  }

  result = TracedOpenAI.structured_output(
    messages: [
      {
        role: "user",
        content: "Extract entities from: Yukihiro Matsumoto created Ruby in Japan. " \
                 "DHH built Rails while at 37signals in Chicago."
      }
    ],
    schema: entity_schema,
    schema_name: "entity_extraction"
  )
  puts "   People found: #{result[:people].map { |p| p[:name] }.join(", ")}"
  puts "   Locations: #{result[:locations].join(", ")}"

  # Example 5: Structured output - Classification
  puts "\n5. Structured output (sentiment classification):"
  sentiment_schema = {
    type: "object",
    properties: {
      sentiment: {
        type: "string",
        enum: %w[positive negative neutral mixed],
        description: "Overall sentiment"
      },
      confidence: {
        type: "number",
        description: "Confidence score 0-1"
      },
      key_phrases: {
        type: "array",
        items: { type: "string" },
        description: "Key phrases that indicate the sentiment"
      },
      reasoning: { type: "string", description: "Brief explanation" }
    },
    required: %w[sentiment confidence key_phrases reasoning],
    additionalProperties: false
  }

  result = TracedOpenAI.structured_output(
    messages: [
      { role: "system", content: "Analyze the sentiment of the given text." },
      { role: "user", content: "I love Ruby! The syntax is beautiful and elegant." }
    ],
    schema: sentiment_schema,
    schema_name: "sentiment_analysis"
  )
  puts "   Sentiment: #{result[:sentiment]} (confidence: #{result[:confidence]})"
  puts "   Reasoning: #{result[:reasoning]}"

  # Example 6: Function calling (tools)
  puts "\n6. Function calling:"
  # Note: With strict: true, ALL properties must be in required
  weather_tools = [
    {
      type: "function",
      function: {
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: {
          type: "object",
          properties: {
            location: { type: "string", description: "City name" },
            unit: { type: "string", enum: %w[celsius fahrenheit], description: "Temperature unit" }
          },
          required: %w[location unit],
          additionalProperties: false
        },
        strict: true
      }
    },
    {
      type: "function",
      function: {
        name: "get_forecast",
        description: "Get weather forecast for upcoming days",
        parameters: {
          type: "object",
          properties: {
            location: { type: "string", description: "City name" },
            days: { type: "integer", description: "Number of days (1-7)" }
          },
          required: %w[location days],
          additionalProperties: false
        },
        strict: true
      }
    }
  ]

  result = TracedOpenAI.function_call(
    messages: [{ role: "user", content: "What's the weather in Tokyo and the 3-day forecast?" }],
    tools: weather_tools
  )
  puts "   Tool calls: #{result.length}"
  result.each do |tc|
    puts "   - #{tc[:function]}(#{tc[:arguments]})"
  end

  # Example 7: RAG chain
  puts "\n7. RAG chain:"
  knowledge = [
    "Ruby is a dynamic, interpreted programming language created by Yukihiro Matsumoto.",
    "Rails is a web application framework written in Ruby.",
    "LangSmith provides observability for LLM applications."
  ]
  rag = RAGChain.new(knowledge_base: knowledge)
  answer = rag.answer("What is Ruby?")
  puts "   Answer: #{answer}"

  # Example 8: Responses API (new OpenAI agent API)
  puts "\n8. Responses API (simple):"
  begin
    result = TracedOpenAI.responses(
      input: "What is the capital of France? Answer in one word.",
      model: "gpt-4o-mini"
    )
    puts "   Output: #{result}"
  rescue StandardError => e
    puts "   (Responses API not available: #{e.message.split("\n").first})"
  end

  # Example 9: Responses API with tools
  puts "\n9. Responses API with tools:"
  begin
    calculator_tools = [
      {
        type: "function",
        name: "calculate",
        description: "Perform a mathematical calculation",
        parameters: {
          type: "object",
          properties: {
            expression: { type: "string", description: "Math expression to evaluate" }
          },
          required: ["expression"],
          additionalProperties: false
        },
        strict: true
      }
    ]

    result = TracedOpenAI.responses_with_tools(
      input: "What is 25 * 4?",
      tools: calculator_tools,
      model: "gpt-4o-mini"
    )
    puts "   Tool calls: #{result.length}"
    result.each do |tc|
      puts "   - #{tc[:name]}(#{tc[:arguments]})"
    end
  rescue StandardError => e
    puts "   (Responses API not available: #{e.message.split("\n").first})"
  end

  # Example 10: Structured output in a traced chain
  puts "\n10. Chained structured extraction:"
  Langsmith.trace("document_analysis_pipeline", run_type: "chain") do |run|
    run.add_metadata(pipeline_version: "1.0")

    # Step 1: Extract entities
    entities = Langsmith.trace("extract_entities", run_type: "chain") do
      TracedOpenAI.structured_output(
        messages: [{ role: "user", content: "Extract from: OpenAI was founded in San Francisco." }],
        schema: {
          type: "object",
          properties: {
            companies: { type: "array", items: { type: "string" } },
            cities: { type: "array", items: { type: "string" } }
          },
          required: %w[companies cities],
          additionalProperties: false
        },
        schema_name: "simple_entities"
      )
    end

    # Step 2: Analyze sentiment
    sentiment = Langsmith.trace("analyze_sentiment", run_type: "chain") do
      TracedOpenAI.structured_output(
        messages: [{ role: "user", content: "Sentiment of: This is amazing news!" }],
        schema: {
          type: "object",
          properties: {
            sentiment: { type: "string", enum: %w[positive negative neutral] },
            score: { type: "number" }
          },
          required: %w[sentiment score],
          additionalProperties: false
        },
        schema_name: "quick_sentiment"
      )
    end

    run.add_metadata(
      entities_found: entities[:companies].length + entities[:cities].length,
      sentiment_result: sentiment[:sentiment]
    )

    { entities: entities, sentiment: sentiment }
  end
  puts "   Pipeline complete!"

  # Flush traces
  Langsmith.shutdown

  puts "\n" + "=" * 60
  puts "Done! Check LangSmith for detailed traces with:"
  puts "- JSON schemas captured in inputs"
  puts "- Parsed structured outputs"
  puts "- Function/tool call details"
  puts "- Full token usage"
  puts "=" * 60
end
