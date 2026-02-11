# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# Pin transitive deps whose latest major versions require Ruby >= 3.2
gem "connection_pool", "~> 2.5"
gem "public_suffix", "~> 6.0"

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.0"
  gem "rubocop-rspec", "~> 3.0"
  gem "webmock", "~> 3.0"
end
