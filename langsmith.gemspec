# frozen_string_literal: true

require_relative "lib/langsmith/version"

Gem::Specification.new do |spec|
  spec.name = "langsmith-sdk"
  spec.version = Langsmith::VERSION
  spec.authors = ["Felipe Cabezudo"]
  spec.email = ["felipecabedilo@gmail.com"]

  spec.summary = "Ruby SDK for LangSmith tracing and observability"
  spec.description = "A Ruby client for LangSmith, providing tracing and observability for LLM applications"
  spec.homepage = "https://github.com/felipekb/langsmith-ruby-sdk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "concurrent-ruby", ">= 1.1", "< 3.0"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-retry", "~> 2.0"
end
