# frozen_string_literal: true

# Example: Complex AI Agent with Simulated Execution Times
#
# This example demonstrates a realistic multi-step AI agent workflow
# with proper timing simulation to generate meaningful traces.
#
# Run with: LANGSMITH_API_KEY=... ruby examples/complex_agent.rb

require_relative "../lib/langsmith"
require "securerandom"

# Configure Langsmith
Langsmith.configure do |config|
  config.api_key = ENV.fetch("LANGSMITH_API_KEY", "your-api-key")
  config.tracing_enabled = true
  config.project = "complex-agent-demo"
end

# Simulated delay to make traces more realistic
def simulate_latency(min_ms, max_ms)
  sleep(rand(min_ms..max_ms) / 1000.0)
end

# =============================================================================
# Simulated LLM and Tool Functions
# =============================================================================

def call_llm(messages, model: "gpt-4", temperature: 0.7, max_tokens: 1000)
  Langsmith.trace("llm.chat", run_type: "llm", inputs: { messages:, model: }) do |run|
    run.set_model(model:, provider: "openai")
    run.add_metadata(temperature:, max_tokens:)

    # Simulate API latency (200-800ms for LLM calls)
    simulate_latency(200, 800)

    # Simulate token counts based on message length
    input_tokens = messages.sum { |m| (m[:content].to_s.length / 4.0).ceil }
    output_tokens = rand(50..300)

    run.set_token_usage(
      input_tokens:,
      output_tokens:,
      total_tokens: input_tokens + output_tokens
    )

    run.add_metadata(
      finish_reason: "stop",
      response_id: "chatcmpl-#{SecureRandom.hex(12)}"
    )

    # Return simulated response
    {
      content: generate_response_for(messages.last[:content]),
      model: model,
      tokens: input_tokens + output_tokens
    }
  end
end

def embed_text(text, model: "text-embedding-3-small")
  Langsmith.trace("llm.embed", run_type: "llm", inputs: { text: text[0..100], model: }) do |run|
    run.set_model(model:, provider: "openai")
    run.add_metadata(dimensions: 1536)

    # Simulate embedding latency (50-150ms)
    simulate_latency(50, 150)

    tokens = (text.length / 4.0).ceil
    # Embeddings only have input tokens
    run.set_token_usage(input_tokens: tokens)

    Array.new(1536) { rand(-1.0..1.0) }
  end
end

def search_vector_db(embedding, collection:, top_k: 5)
  Langsmith.trace("vector_db.search", run_type: "retriever", inputs: { collection: collection, top_k: top_k }) do |run|
    run.add_metadata(
      database: "pinecone",
      collection: collection,
      top_k: top_k,
      metric: "cosine"
    )

    # Simulate DB latency (30-100ms)
    simulate_latency(30, 100)

    results = top_k.times.map do |i|
      {
        id: "doc-#{SecureRandom.hex(4)}",
        score: (0.95 - i * 0.05).round(3),
        content: "Document #{i + 1}: This is relevant context about the query topic."
      }
    end

    run.add_metadata(results_count: results.length, max_score: results.first[:score])
    results
  end
end

def search_web(query)
  Langsmith.trace("tool.web_search", run_type: "tool", inputs: { query: query }) do |run|
    run.add_metadata(engine: "tavily", max_results: 5)

    # Simulate web search latency (300-600ms)
    simulate_latency(300, 600)

    results = [
      { title: "#{query} - Wikipedia", url: "https://en.wikipedia.org/wiki/#{query.gsub(' ', '_')}", snippet: "Overview of #{query}..." },
      { title: "#{query} Guide", url: "https://example.com/guide", snippet: "Complete guide to #{query}..." },
      { title: "Understanding #{query}", url: "https://blog.example.com/#{query}", snippet: "Deep dive into #{query}..." }
    ]

    run.add_metadata(results_count: results.length)
    results
  end
end

def execute_code(code, language: "python")
  Langsmith.trace("tool.code_execution", run_type: "tool", inputs: { code: code, language: language }) do |run|
    run.add_metadata(language: language, sandbox: "docker")

    # Simulate code execution (100-500ms)
    simulate_latency(100, 500)

    output = "Execution successful. Result: 42"
    run.add_metadata(exit_code: 0, execution_time_ms: rand(50..200))

    { success: true, output: output }
  end
end

def generate_response_for(query)
  responses = {
    /search|find|look up/i => "I found several relevant results for your query.",
    /calculate|compute|math/i => "Based on my calculations, the answer is 42.",
    /code|program|script/i => "I've executed the code and here are the results.",
    /summarize|summary/i => "Here's a concise summary of the information.",
    /explain|what is/i => "Let me explain this concept in detail.",
  }

  responses.each do |pattern, response|
    return response if query.match?(pattern)
  end

  "I've processed your request and here's my response based on the available information."
end

# =============================================================================
# Complex Agent Implementation
# =============================================================================

class ResearchAgent
  def initialize
    @conversation_history = []
  end

  def run(user_query)
    Langsmith.trace("research_agent.run", run_type: "chain", inputs: { query: user_query }) do
      @conversation_history << { role: "user", content: user_query }

      plan = plan_execution(user_query)
      results = execute_plan(plan)
      response = synthesize_response(user_query, results)

      @conversation_history << { role: "assistant", content: response }
      response
    end
  end

  private

  def plan_execution(query)
    Langsmith.trace("agent.plan", run_type: "chain", inputs: { query: query }) do |run|
      run.add_metadata(planner_version: "v2")

      # Call LLM to create a plan
      planning_response = call_llm([
        { role: "system", content: "You are a planning agent. Analyze the query and create an execution plan." },
        { role: "user", content: "Create a plan for: #{query}" }
      ], model: "gpt-4", temperature: 0.3)

      # Simulate plan based on query type
      plan = determine_plan_steps(query)
      run.add_metadata(steps_count: plan.length, plan_type: plan.first[:type])

      plan
    end
  end

  def determine_plan_steps(query)
    if query.match?(/research|learn about|what is/i)
      [
        { type: "retrieve", action: "Search knowledge base" },
        { type: "web_search", action: "Search web for recent info" },
        { type: "synthesize", action: "Combine and summarize" }
      ]
    elsif query.match?(/calculate|compute|analyze data/i)
      [
        { type: "retrieve", action: "Get relevant formulas" },
        { type: "code", action: "Execute calculation" },
        { type: "synthesize", action: "Explain results" }
      ]
    else
      [
        { type: "retrieve", action: "Search knowledge base" },
        { type: "synthesize", action: "Generate response" }
      ]
    end
  end

  def execute_plan(plan)
    Langsmith.trace("agent.execute_plan", run_type: "chain", inputs: { plan: plan }) do |run|
      run.add_metadata(total_steps: plan.length)

      results = []

      plan.each_with_index do |step, index|
        step_result = execute_step(step, index + 1, results)
        results << step_result
        run.add_event(name: "step_completed", step: index + 1, type: step[:type])
      end

      run.add_metadata(completed_steps: results.length, success: true)
      results
    end
  end

  def execute_step(step, step_number, previous_results)
    Langsmith.trace("agent.step_#{step_number}", run_type: "chain", inputs: { step: step }) do |run|
      run.add_metadata(step_number: step_number, step_type: step[:type])
      run.add_tags("step", step[:type])

      result = case step[:type]
               when "retrieve"
                 execute_retrieval_step
               when "web_search"
                 execute_web_search_step
               when "code"
                 execute_code_step
               when "synthesize"
                 execute_synthesis_step(previous_results)
               else
                 { type: step[:type], data: "Unknown step type" }
               end

      run.add_metadata(result_type: result[:type])
      result
    end
  end

  def execute_retrieval_step
    Langsmith.trace("retrieval_pipeline", run_type: "chain") do |run|
      # Embed the query
      query_embedding = embed_text("user query for knowledge base search")

      # Search vector DB
      kb_results = search_vector_db(query_embedding, collection: "knowledge_base", top_k: 3)

      run.add_metadata(documents_retrieved: kb_results.length)

      { type: "retrieval", data: kb_results }
    end
  end

  def execute_web_search_step
    results = search_web("latest information on the topic")
    { type: "web_search", data: results }
  end

  def execute_code_step
    code = <<~PYTHON
      import math
      result = math.sqrt(1764)
      print(f"The answer is {result}")
    PYTHON

    execution_result = execute_code(code, language: "python")
    { type: "code_execution", data: execution_result }
  end

  def execute_synthesis_step(previous_results)
    Langsmith.trace("synthesis", run_type: "chain", inputs: { results_count: previous_results.length }) do |run|
      # Prepare context from previous results
      context = previous_results.map { |r| r[:data].to_s }.join("\n\n")

      # Call LLM to synthesize
      synthesis = call_llm([
        { role: "system", content: "Synthesize the following information into a coherent response." },
        { role: "user", content: "Information to synthesize:\n#{context}" }
      ], model: "gpt-4", temperature: 0.5)

      run.add_metadata(context_length: context.length, synthesis_tokens: synthesis[:tokens])

      { type: "synthesis", data: synthesis[:content] }
    end
  end

  def synthesize_response(query, results)
    Langsmith.trace("final_response", run_type: "llm", inputs: { query: }) do |run|
      run.set_model(model: "gpt-4", provider: "openai")
      run.add_metadata(results_count: results.length)

      # Final LLM call to generate response
      response = call_llm([
        { role: "system", content: "Generate a helpful, comprehensive response based on the research results." },
        { role: "user", content: "Query: #{query}\n\nResearch results: #{results.map { |r| r[:data] }.join("\n")}" }
      ], model: "gpt-4", temperature: 0.7, max_tokens: 500)

      input_tokens = rand(200..400)
      output_tokens = rand(100..300)
      run.set_token_usage(input_tokens:, output_tokens:, total_tokens: input_tokens + output_tokens)

      response[:content]
    end
  end
end

# =============================================================================
# Multi-Agent Collaboration Example
# =============================================================================

def run_multi_agent_task(task)
  Langsmith.trace("multi_agent.orchestrator", run_type: "chain", inputs: { task: task }) do |run|
    run.add_metadata(agent_count: 3, task_type: "collaborative")
    run.add_tags("multi-agent", "production")

    # Agent 1: Research
    research_result = Langsmith.trace("agent.researcher", run_type: "chain") do |agent_run|
      agent_run.add_metadata(agent_role: "researcher", specialization: "information_gathering")

      simulate_latency(100, 200)
      embed_text(task)
      docs = search_vector_db([], collection: "research_papers", top_k: 5)
      web = search_web(task)

      call_llm([
        { role: "system", content: "You are a research specialist." },
        { role: "user", content: "Research: #{task}" }
      ], model: "gpt-4")

      { findings: docs.length + web.length, summary: "Research completed successfully" }
    end

    # Agent 2: Analyst
    analysis_result = Langsmith.trace("agent.analyst", run_type: "chain") do |agent_run|
      agent_run.add_metadata(agent_role: "analyst", specialization: "data_analysis")

      simulate_latency(100, 200)

      # Multiple analysis sub-steps
      Langsmith.trace("analysis.data_processing", run_type: "tool") do |step|
        simulate_latency(50, 150)
        step.add_metadata(records_processed: rand(100..1000))
      end

      Langsmith.trace("analysis.statistical", run_type: "tool") do |step|
        simulate_latency(100, 200)
        step.add_metadata(metrics_computed: ["mean", "median", "std_dev"])
      end

      call_llm([
        { role: "system", content: "You are a data analyst." },
        { role: "user", content: "Analyze findings: #{research_result[:summary]}" }
      ], model: "gpt-4")

      { insights: 5, confidence: 0.87 }
    end

    # Agent 3: Writer
    final_output = Langsmith.trace("agent.writer", run_type: "chain") do |agent_run|
      agent_run.add_metadata(agent_role: "writer", specialization: "content_creation")

      simulate_latency(100, 200)

      # Generate outline
      Langsmith.trace("writing.outline", run_type: "llm") do |step|
        step.set_model(model: "gpt-4", provider: "openai")
        simulate_latency(150, 300)
        step.set_token_usage(input_tokens: 100, output_tokens: 150, total_tokens: 250)
      end

      # Write draft
      Langsmith.trace("writing.draft", run_type: "llm") do |step|
        step.set_model(model: "gpt-4", provider: "openai")
        simulate_latency(300, 600)
        step.set_token_usage(input_tokens: 300, output_tokens: 500, total_tokens: 800)
      end

      # Polish
      response = call_llm([
        { role: "system", content: "You are a professional writer." },
        { role: "user", content: "Write a comprehensive report based on: Research=#{research_result[:summary]}, Analysis=#{analysis_result[:insights]} insights" }
      ], model: "gpt-4", max_tokens: 1000)

      response[:content]
    end

    run.add_metadata(
      research_findings: research_result[:findings],
      analysis_insights: analysis_result[:insights],
      output_length: final_output.length
    )

    final_output
  end
end

# =============================================================================
# Run Examples
# =============================================================================

if __FILE__ == $PROGRAM_NAME
  puts "=" * 70
  puts "Complex AI Agent Tracing Demo"
  puts "=" * 70
  puts

  # Example 1: Multi-Agent Collaboration (MOVED TO FIRST to test if order matters)
  puts "Running Multi-Agent Collaboration FIRST..."
  puts "-" * 40

  start_time = Time.now
  result = run_multi_agent_task("Analyze market trends for renewable energy sector")
  elapsed = ((Time.now - start_time) * 1000).round
  puts "Result: #{result[0..100]}..."
  puts "Time: #{elapsed}ms"

  # Example 2: Research Agent (now runs after multi-agent)
  puts "\n"
  puts "=" * 70
  puts "Running Research Agent..."
  puts "-" * 40
  agent = ResearchAgent.new

  queries = [
    "What is quantum computing and how does it work?",
    "Calculate the optimal portfolio allocation for a $100k investment",
    "Analyze market trends for renewable energy sector",
    "Analyze market trends for renewable energy sector",
    "Analyze market trends for renewable energy sector",
  ]

  queries.each_with_index do |query, i|
    puts "\nQuery #{i + 1}: #{query}"
    start_time = Time.now
    result = agent.run(query)
    elapsed = ((Time.now - start_time) * 1000).round
    puts "Response: #{result[0..100]}..."
    puts "Time: #{elapsed}ms"
  end

  # Flush all traces
  sleep 10
  puts "\nFlushing traces..."
  Langsmith.shutdown

  puts "\n"
  puts "=" * 70
  puts "All traces sent to LangSmith!"
  puts "Check your dashboard at https://smith.langchain.com"
  puts "Project: complex-agent-demo"
  puts "=" * 70
end

