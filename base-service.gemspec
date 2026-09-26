# frozen_string_literal: true

require_relative "lib/base_service/version"

Gem::Specification.new do |spec|
  spec.name = "base-service"
  spec.version = Service::VERSION
  spec.authors = ["Nicolas Vandenbogaerde"]

  spec.summary = "An immutable base class for Ruby service objects"
  spec.description = "Build service objects with isolated execution contexts, immutable results, and named callbacks."
  spec.homepage = "https://github.com/nicolasva/base-service"
  spec.required_ruby_version = ">= 2.7"

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage

  spec.add_dependency "callback-collection", "~> 0.2"

  spec.add_development_dependency "minitest", ">= 5", "< 7"
  spec.add_development_dependency "rake", "~> 13.0"
end
