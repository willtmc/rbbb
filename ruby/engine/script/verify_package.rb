# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "rbconfig"
require "rubygems/installer"
require "rubygems/package"
require "tmpdir"

ENGINE_ROOT = Pathname(__dir__).join("..").expand_path
REPOSITORY_ROOT = ENGINE_ROOT.join("../..").expand_path
GEMSPEC_PATH = ENGINE_ROOT.join("rbbb.gemspec")
EXPECTED_FILES = %w[
  LICENSE
  README.md
  lib/rbbb.rb
  lib/rbbb/configuration.rb
  lib/rbbb/decision.rb
  lib/rbbb/engine.rb
  lib/rbbb/event.rb
  lib/rbbb/increment_schedule.rb
  lib/rbbb/money.rb
  lib/rbbb/state.rb
  lib/rbbb/timestamp.rb
  lib/rbbb/version.rb
].freeze

def fail_verification(message)
  warn "Package verification failed: #{message}"
  exit 1
end

specification = Gem::Specification.load(GEMSPEC_PATH.to_s)
fail_verification("could not load #{GEMSPEC_PATH}") unless specification
fail_verification("version must be a prerelease") unless specification.version.prerelease?
unless specification.runtime_dependencies.empty?
  fail_verification("evaluation gem must remain free of runtime dependencies")
end
unless specification.files.sort == EXPECTED_FILES
  fail_verification("unexpected gem files: #{specification.files.sort.inspect}")
end
unless specification.metadata.fetch("rbbb_specification_version") == RBBB::SPECIFICATION_VERSION
  fail_verification("gemspec and runtime specification versions differ")
end
unless specification.metadata.fetch("rbbb_release_status") == "experimental"
  fail_verification("evaluation gem must remain experimental")
end
canonical_specification_version = REPOSITORY_ROOT.join("specification/VERSION").read.strip
unless RBBB::SPECIFICATION_VERSION == canonical_specification_version
  fail_verification("runtime and canonical specification versions differ")
end

unreadable = specification.files.reject { |file| ENGINE_ROOT.join(file).world_readable? }
fail_verification("files are not world-readable: #{unreadable.join(', ')}") if unreadable.any?

Dir.mktmpdir("rbbb-package-") do |temporary_directory|
  temporary_root = Pathname(temporary_directory)
  gem_path = temporary_root.join("rbbb-#{specification.version}.gem")

  Dir.chdir(ENGINE_ROOT) do
    Gem::Package.build(specification, false, true, gem_path.to_s)
  end

  extracted_root = temporary_root.join("extracted")
  Gem::Package.new(gem_path.to_s).extract_files(extracted_root.to_s)
  extracted_files = Dir.chdir(extracted_root) do
    Dir.glob("**/*", File::FNM_DOTMATCH).reject do |entry|
      entry == "." || entry == ".." || File.directory?(entry)
    end.sort
  end
  unless extracted_files == EXPECTED_FILES
    fail_verification("built artifact contains unexpected files: #{extracted_files.inspect}")
  end

  install_root = temporary_root.join("installed")
  Gem::Installer.at(
    gem_path.to_s,
    install_dir: install_root.to_s,
    wrappers: false,
    ignore_dependencies: true
  ).install

  smoke_code = <<~'RUBY'
    require "json"
    require "rbbb"

    configuration = RBBB::Configuration.new(
      currency: "USD",
      opening_minor_units: 1_000,
      increments: [{from_minor_units: 0, amount_minor_units: 100}]
    )
    engine = RBBB::Engine.new(configuration)
    state = engine.initial_state
    decision = engine.decide(state, {
      command_id: "evaluation-command",
      type: "place_bid",
      bidder_id: "evaluation-bidder",
      maximum_minor_units: 5_000
    })
    abort "installed gem rejected smoke bid" unless decision.accepted?
    state = engine.apply(state, decision.events)
    abort "installed gem produced wrong standing amount" unless state.standing_minor_units == 1_000

    puts JSON.generate(
      version: RBBB::VERSION,
      specification_version: RBBB::SPECIFICATION_VERSION,
      release_status: RBBB::RELEASE_STATUS
    )
  RUBY
  bundler_environment = ENV.each_key.grep(/\A(?:BUNDLE|BUNDLER)_/).to_h do |key|
    [key, nil]
  end
  environment = bundler_environment.merge(
    "GEM_HOME" => install_root.to_s,
    "GEM_PATH" => install_root.to_s,
    "RUBYGEMS_GEMDEPS" => nil,
    "RUBYLIB" => nil,
    "RUBYOPT" => nil
  )
  stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-e", smoke_code)
  fail_verification("installed smoke test failed: #{stderr}") unless status.success?

  smoke_result = JSON.parse(stdout)
  expected_result = {
    "version" => specification.version.to_s,
    "specification_version" => RBBB::SPECIFICATION_VERSION,
    "release_status" => "experimental"
  }
  unless smoke_result == expected_result
    fail_verification("installed metadata differs: #{smoke_result.inspect}")
  end

  puts "Verified #{gem_path.basename}: #{extracted_files.length} files, clean install, and bid smoke test."
end
