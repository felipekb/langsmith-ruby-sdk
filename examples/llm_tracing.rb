# frozen_string_literal: true

# Example: Tracing LLM calls with token usage
#
# This example demonstrates how to trace LLM API calls and capture
# token usage, model information, and other metadata.
#
# Follows Python SDK patterns for compatibility with LangSmith UI:
# - Uses set_model() for model/provider metadata (ls_model_name, ls_provider)
# - Uses input_tokens/output_tokens in set_token_usage()
# - Uses "new_token" event for streaming TTFT tracking
#
# Run with: ruby examples/llm_tracing.rb

require_relative "../lib/langsmith"

# Configure Langsmith
Langsmith.configure do |config|
  config.api_key = ENV.fetch("LANGSMITH_API_KEY", "your-api-key")
  config.tracing_enabled = true
  config.project = "llm-examples"
end

# Example 1: Basic LLM call tracing with token usage
def trace_openai_chat(messages, model: "gpt-4")
  Langsmith.trace("openai_chat", run_type: "llm", inputs: { messages:, model: }) do |run|
    # Set model info using Python SDK pattern (stored in extra.metadata)
    run.set_model(model:, provider: "openai")
    run.add_metadata(temperature: 0.7)

    # Simulate OpenAI API call
    # In real code, you'd call: response = client.chat.completions.create(...)
    response = simulate_openai_response(messages, model)

    # Set token usage from the API response (Python SDK uses input_tokens/output_tokens)
    run.set_token_usage(
      input_tokens: response[:usage][:prompt_tokens],
      output_tokens: response[:usage][:completion_tokens],
      total_tokens: response[:usage][:total_tokens]
    )

    # Add response metadata
    run.add_metadata(
      finish_reason: response[:choices].first[:finish_reason],
      response_id: response[:id]
    )

    # Return the response content
    response[:choices].first[:message][:content]
  end
end

# Example 2: Streaming LLM call with TTFT tracking (Python SDK pattern)
def trace_streaming_llm(prompt)
  Langsmith.trace("streaming_chat", run_type: "llm", inputs: { prompt: }) do |run|
    run.set_model(model: "gpt-4", provider: "openai")
    run.add_metadata(streaming: true)

    # Track tokens and timing as we stream
    total_output_tokens = 0
    full_response = ""
    first_token_logged = false
    stream_start_time = Time.now

    # Simulate streaming chunks
    chunks = simulate_streaming_response(prompt)
    chunks.each_with_index do |chunk, index|
      # Add "new_token" event for FIRST token only (Python SDK pattern)
      # LangSmith uses this to calculate time-to-first-token
      unless first_token_logged
        run.add_event(name: "new_token", time: Time.now.utc, token: chunk[:content])
        first_token_logged = true
      end

      full_response += chunk[:content]
      total_output_tokens += chunk[:tokens]

      # Simulate streaming delay
      sleep(0.05) if index < chunks.length - 1
    end

    stream_end_time = Time.now
    tokens_per_second = (total_output_tokens / (stream_end_time - stream_start_time)).round(2)

    # Set final token usage (Python SDK uses input_tokens/output_tokens)
    run.set_token_usage(
      input_tokens: estimate_prompt_tokens(prompt),
      output_tokens: total_output_tokens,
      total_tokens: estimate_prompt_tokens(prompt) + total_output_tokens
    )

    run.add_metadata(tokens_per_second:)

    full_response
  end
end

# Example 3: Chain with multiple LLM calls
def trace_llm_chain(user_question)
  Langsmith.trace("question_answer_chain", run_type: "chain", inputs: { question: user_question }) do |chain_run|
    chain_run.add_metadata(chain_type: "qa_with_context")
    chain_run.add_tags("qa", "production")

    # Step 1: Generate search query
    search_query = Langsmith.trace("generate_search_query", run_type: "llm") do |run|
      run.set_model(model: "gpt-3.5-turbo", provider: "openai")
      run.add_metadata(purpose: "query_generation")

      prompt = "Generate a search query for: #{user_question}"
      response = simulate_quick_llm_call(prompt)

      run.set_token_usage(input_tokens: 25, output_tokens: 15)
      response
    end

    # Step 2: Retrieve context (tool call)
    context = Langsmith.trace("retrieve_context", run_type: "retriever") do |run|
      run.add_metadata(index: "knowledge_base", top_k: 3)

      # Simulate retrieval
      ["Context 1: Ruby is a programming language.",
       "Context 2: LangSmith provides observability.",
       "Context 3: Tracing helps debug LLM apps."]
    end

    # Step 3: Generate final answer
    answer = Langsmith.trace("generate_answer", run_type: "llm") do |run|
      run.set_model(model: "gpt-4", provider: "openai")
      run.add_metadata(purpose: "answer_generation")

      messages = [
        { role: "system", content: "Answer based on context: #{context.join("\n")}" },
        { role: "user", content: user_question }
      ]

      response = simulate_openai_response(messages, "gpt-4")

      run.set_token_usage(
        input_tokens: response[:usage][:prompt_tokens],
        output_tokens: response[:usage][:completion_tokens],
        total_tokens: response[:usage][:total_tokens]
      )

      response[:choices].first[:message][:content]
    end

    answer
  end
end

# Example 4: Using Traceable module for LLM service class
class LLMService
  include Langsmith::Traceable

  def initialize(model: "gpt-4", temperature: 0.7)
    @model = model
    @temperature = temperature
  end

  traceable run_type: "llm", name: "llm_service.chat"
  def chat(messages)
    # In real code: response = @client.chat.completions.create(...)
    response = simulate_openai_response(messages, @model)

    # Access current run to set model and token usage (Python SDK pattern)
    if (run = Langsmith.current_run)
      run.set_model(model: @model, provider: "openai")
      run.set_token_usage(
        input_tokens: response[:usage][:prompt_tokens],
        output_tokens: response[:usage][:completion_tokens],
        total_tokens: response[:usage][:total_tokens]
      )
      run.add_metadata(temperature: @temperature)
    end

    response[:choices].first[:message][:content]
  end

  traceable run_type: "llm", name: "llm_service.embed"
  def embed(text)
    # Simulate embedding call
    tokens_used = (text.length / 4.0).ceil

    if (run = Langsmith.current_run)
      run.set_model(model: "text-embedding-3-small", provider: "openai")
      # Embeddings only have input tokens, no output tokens
      run.set_token_usage(input_tokens: tokens_used)
      run.add_metadata(dimensions: 1536)
    end

    Array.new(1536) { rand(-1.0..1.0) }
  end
end

# Example 5: Error handling with LLM calls
def trace_with_error_handling(prompt)
  Langsmith.trace("llm_with_retry", run_type: "llm", inputs: { prompt: }) do |run|
    run.set_model(model: "gpt-4", provider: "openai")
    run.add_metadata(max_retries: 3)

    retries = 0
    begin
      # Simulate potential failure
      if rand < 0.3 && retries < 2
        retries += 1
        run.add_event(name: "retry", attempt: retries, reason: "rate_limited")
        raise "Rate limited"
      end

      response = simulate_openai_response([{ role: "user", content: prompt }], "gpt-4")
      run.set_token_usage(
        input_tokens: response[:usage][:prompt_tokens],
        output_tokens: response[:usage][:completion_tokens],
        total_tokens: response[:usage][:total_tokens]
      )
      run.add_metadata(retries:)

      response[:choices].first[:message][:content]
    rescue StandardError => e
      run.add_event(name: "error", message: e.message)
      retry if retries < 3
      raise
    end
  end
end

# ============================================================================
# Helper methods to simulate API responses (replace with real API calls)
# ============================================================================

def simulate_openai_response(messages, model)
  prompt_tokens = messages.sum { |m| (m[:content].length / 4.0).ceil }
  completion_tokens = rand(50..200)

  {
    id: "chatcmpl-#{SecureRandom.hex(12)}",
    model: model,
    choices: [
      {
        index: 0,
        message: { role: "assistant", content: "This is a simulated response from #{model}." },
        finish_reason: "stop"
      }
    ],
    usage: {
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      total_tokens: prompt_tokens + completion_tokens
    }
  }
end

def simulate_streaming_response(prompt)
  words = %w[This is a simulated streaming response from the LLM model.]
  words.map { |word| { content: "#{word} ", tokens: 1 } }
end

def simulate_quick_llm_call(prompt)
  "search query for: #{prompt.split(":").last.strip}"
end

def estimate_prompt_tokens(text)
  (text.length / 4.0).ceil
end

# ============================================================================
# Run the examples
# ============================================================================

if __FILE__ == $PROGRAM_NAME
  puts "=" * 60
  puts "LangSmith LLM Tracing Examples"
  puts "=" * 60

  puts "\n1. Basic LLM call with token usage:"
  result = trace_openai_chat([{ role: "user", content: "What is Ruby?" }])
  puts "   Response: #{result}"

  puts "\n2. Streaming LLM call:"
  result = trace_streaming_llm("Tell me about Ruby programming")
  puts "   Response: #{result}"

  puts "\n3. Multi-step LLM chain:"
  result = trace_llm_chain("How do I trace LLM calls?")
  puts "   Response: #{result}"

  puts "\n4. Using Traceable module:"
  service = LLMService.new(model: "gpt-4", temperature: 0.5)
  result = service.chat([{ role: "user", content: "Hello!" }])
  puts "   Chat response: #{result}"
  embedding = service.embed("Hello world")
  puts "   Embedding dimensions: #{embedding.length}"

  puts "\n5. Error handling:"
  result = trace_with_error_handling("Test prompt")
  puts "   Response: #{result}"

  # Ensure all traces are sent before exiting
  Langsmith.shutdown

  puts "\n" + "=" * 60
  puts "All examples completed! Check LangSmith for traces."
  puts "=" * 60
end
