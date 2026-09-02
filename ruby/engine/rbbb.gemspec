# frozen_string_literal: true

require_relative "lib/rbbb/version"

Gem::Specification.new do |spec|
  spec.name = "rbbb"
  spec.version = RBBB::VERSION
  spec.authors = ["R Triple B contributors"]
  spec.email = ["will@mclemoreauction.com"]

  spec.summary = "Experimental Ruby reference engine for deterministic auction bidding"
  spec.description = <<~DESCRIPTION.strip
    An evaluation build of the pure-Ruby reference implementation for the
    language-neutral RBBB bidding specification. It is not production ready.
  DESCRIPTION
  spec.homepage = "https://github.com/willtmc/rbbb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  release_tag = "v#{spec.version}"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "bug_tracker_uri" => "https://github.com/willtmc/rbbb/issues",
    "changelog_uri" => "https://github.com/willtmc/rbbb/blob/#{release_tag}/CHANGELOG.md",
    "documentation_uri" => "https://github.com/willtmc/rbbb/blob/#{release_tag}/ruby/engine/README.md",
    "homepage_uri" => spec.homepage,
    "rbbb_release_status" => RBBB::RELEASE_STATUS,
    "rbbb_rfc" => "0001",
    "rbbb_specification_version" => RBBB::SPECIFICATION_VERSION,
    "rubygems_mfa_required" => "true",
    "source_code_uri" => "https://github.com/willtmc/rbbb/tree/#{release_tag}/ruby/engine"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "README.md", "LICENSE"].sort
  end
  spec.extra_rdoc_files = ["README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 6.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
