# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-12-21

### Added

- Initial release of the LangSmith Ruby SDK
- Block-based tracing with `Langsmith.trace`
- Method decoration with `Langsmith::Traceable` module
- Automatic parent-child trace linking for nested traces
- Thread-safe batch processing with background worker
- Fiber-local context support for Ruby 3.2+ async frameworks
- Multi-tenant support with per-trace `tenant_id` override
- Token usage tracking with `set_token_usage`
- Model metadata with `set_model`
- Streaming metrics with `set_streaming_metrics`
- Event tracking with `add_event`
- Configurable via environment variables or programmatic configuration
- Automatic retry with exponential backoff for failed API requests
- Graceful shutdown with `at_exit` hook

### Run Types

- `chain` - A sequence of operations
- `llm` - LLM API calls
- `tool` - Tool/function executions
- `retriever` - Document retrieval operations
- `prompt` - Prompt template rendering
- `parser` - Output parsing operations

[Unreleased]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/felipekb/langsmith-ruby-sdk/releases/tag/v0.1.0

