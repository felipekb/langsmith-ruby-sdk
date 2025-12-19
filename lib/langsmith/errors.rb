# frozen_string_literal: true

module Langsmith
  # Base error class for all Langsmith errors.
  # All custom errors inherit from this class.
  class Error < StandardError; end

  # Raised when configuration is invalid or incomplete.
  class ConfigurationError < Error; end

  # Raised when tracing operations fail.
  class TracingError < Error; end
end
