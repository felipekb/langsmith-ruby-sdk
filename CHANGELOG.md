# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-02-17

### Added

- Multi-tenant evaluation support with `tenant_id` parameter in `ExperimentRunner`
- Context tracking for evaluation root run tenant ID
- Tenant ID propagation to dataset, experiment, and feedback API calls

### Changed

- Improved experiment cleanup with ensure block in `ExperimentRunner#run`

## [0.3.2] - 2026-02-11

### Fixed

- Pin `connection_pool` to ~> 2.5 (`connection_pool` >= 3.0 requires Ruby >= 3.2, breaking installs on Ruby 3.1)

## [0.3.1] - 2026-02-11

### Fixed

- Pin `connection_pool` to 2.5.5 (3.0.2 was yanked from RubyGems, breaking installs on Ruby 3.1)

## [0.3.0] - 2026-02-11

### Added

- Evaluation module and `ExperimentRunner` for running experiments against datasets
- Evaluator protocol with support for custom evaluators in `ExperimentRunner`
- `Client#create_feedback` for submitting evaluation feedback (`POST /api/v1/feedback`)
- `Client#read_run` for fetching run details (`GET /api/v1/runs/:run_id`)
- Evaluation API methods: `list_examples`, `create_experiment`, `close_experiment`
- Evaluation context wired into run creation
- Root run ID tracking in evaluation context and `RunTree`
- `reference_example_id` and `session_id` attributes on `Run`

### Fixed

- Retry with delay for `read_run` after flush for reliable evaluation reads
- Graceful error handling separating user block errors from evaluator errors
- Root run ID read before `with_evaluation` clears it

## [0.2.0] - 2025-12-21

### Added

- `max_pending_entries` configuration option to limit buffer size and prevent unbounded memory growth
- Configurable via `LANGSMITH_MAX_PENDING_ENTRIES` environment variable

### Changed

- Improved BatchProcessor thread safety with dedicated mutexes for pending arrays and flush operations
- Better error logging in BatchProcessor with stack traces for debugging
- Run data is now serialized on the calling thread to ensure correct state capture

### Removed

- **BREAKING**: Removed `Langsmith::Traceable` module - use `Langsmith.trace` block-based API instead

## [0.1.1] - 2025-12-21

### Added

- Per-trace `project` parameter to override the default project at runtime
- Child traces automatically inherit project from parent (enforced)

## [0.1.0] - 2025-12-21

### Added

- Initial release of the LangSmith Ruby SDK
- Block-based tracing with `Langsmith.trace`
- Automatic parent-child trace linking for nested traces
- Thread-safe batch processing with background worker
- Thread-local context for proper isolation in concurrent environments
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

[Unreleased]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.3.2...v0.4.0
[0.3.2]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/felipekb/langsmith-ruby-sdk/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/felipekb/langsmith-ruby-sdk/releases/tag/v0.1.0

