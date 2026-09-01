# frozen_string_literal: true

require_relative "lib/rbbb/version"

Gem::Specification.new do |spec|
  spec.name = "rbbb"
  spec.version = RBBB::VERSION
  spec.authors = ["R Triple B contributors"]
  spec.email = ["will@mclemoreauction.com"]

  spec.summary = "A deterministic, auditable auction bidding engine"
  spec.description = "The pure-Ruby reference implementation of the language-neutral RBBB bidding specification."
  spec.homepage = "https://github.com/willtmc/rbbb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/willtmc/rbbb/issues",
    "changelog_uri" => "https://github.com/willtmc/rbbb/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/willtmc/rbbb#readme",
    "homepage_uri" => spec.homepage,
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "README.md", "LICENSE"].sort
  end
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.20"
  spec.add_development_dependency "rake", "~> 13.0"
end
