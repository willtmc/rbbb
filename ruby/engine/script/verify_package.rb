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
  lib/rbbb/bid_ladder.rb
  lib/rbbb/configuration.rb
  lib/rbbb/decision.rb
  lib/rbbb/engine.rb
  lib/rbbb/event.rb
  lib/rbbb/increment_schedule.rb
  lib/rbbb/initial_closing_schedule.rb
  lib/rbbb/live_scheduling.rb
  lib/rbbb/live_scheduling/coordinator.rb
  lib/rbbb/live_scheduling/intent.rb
  lib/rbbb/live_scheduling/projector.rb
  lib/rbbb/money.rb
  lib/rbbb/shared_closing_clock.rb
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
release_tag = "v#{specification.version}"
%w[changelog_uri documentation_uri source_code_uri].each do |key|
  unless specification.metadata.fetch(key).include?(release_tag)
    fail_verification("#{key} must identify the immutable #{release_tag} source")
  end
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
      increments: [{from_minor_units: 0, amount_minor_units: 100}],
      opens_at: "2026-09-01T12:00:00Z",
      closes_at: "2026-09-01T13:00:00Z"
    )
    engine = RBBB::Engine.new(configuration)
    state = engine.initial_state
    decision = engine.decide(state, {
      command_id: "evaluation-command",
      type: "place_bid",
      bidder_id: "evaluation-bidder",
      effective_at: "2026-09-01T12:30:00Z",
      maximum_minor_units: 5_000
    })
    abort "installed gem rejected smoke bid" unless decision.accepted?
    state = engine.apply(state, decision.events)
    abort "installed gem produced wrong standing amount" unless state.standing_minor_units == 1_000

    schedule = RBBB::InitialClosingSchedule.plan(unit_ids: %w[a b c],
      opens_at: "2030-01-01T12:00:00Z", first_closes_at: "2030-01-01T13:00:00Z",
      lots_per_minute: 2, groups: [{"group_id" => "g", "unit_ids" => %w[a c]}])
    abort "installed planner returned wrong group deadline" unless schedule.fetch("unit_closes_at").fetch("a") == "2030-01-01T13:01:00Z"

    clock = RBBB::SharedClosingClock.new(group_id: "g", unit_ids: %w[a c],
      closes_at: "2026-09-01T13:00:00Z", quiet_period_seconds: 180)
    late = engine.decide(state, command_id: "late", type: "place_bid", bidder_id: "challenger",
      maximum_minor_units: 6_000, effective_at: "2026-09-01T12:59:00Z")
    extended = clock.after_decision(unit_id: "a", decision: late, expected_revision: 0)
    abort "installed group clock did not extend" unless RBBB::Timestamp.dump(extended.deadline_for("c")) == "2026-09-01T13:02:00Z"

    require "rbbb/live_scheduling"
    config = {"currency" => "USD", "opening_minor_units" => 1000,
      "increments" => [{"from_minor_units" => 0, "amount_minor_units" => 100}],
      "opens_at" => "2026-09-01T12:00:00Z", "closes_at" => "2026-09-01T13:00:00Z"}
    closing_set = {"group_id" => "evaluation-group", "member_unit_ids" => ["a", "c"], "closes_at" => config["closes_at"],
      "extension" => {"trigger_window_seconds" => 60, "duration_seconds" => 180}}
    coordinator_args = {auction_id: "evaluation-auction", configurations: {"a" => config, "c" => config},
      policy: {"minimum_shortening_lead_seconds" => 180}}
    snapshot = {"schedule_revision" => 0, "closing_sets" => [closing_set],
      "units" => {"a" => state.to_h, "c" => RBBB::State.empty(RBBB::Configuration.from_h(config)).to_h}}
    coordinator = RBBB::LiveScheduling::Coordinator.new(**coordinator_args, snapshot: snapshot)
    intent = {"capability" => RBBB::LiveScheduling::CAPABILITY, "type" => "revise_closing_schedule",
      "command_id" => "evaluation-edit", "auction_id" => "evaluation-auction", "expected_schedule_revision" => 0,
      "expected_units" => [{"unit_id" => "a", "version" => state.version}, {"unit_id" => "c", "version" => 0}], "reason" => "Synthetic package check",
      "allow_shortening" => false, "resulting_closing_sets" => [closing_set.merge("closes_at" => "2026-09-01T13:10:00Z")], "retired_group_ids" => []}
    result = coordinator.edit(intent: intent, principal_id: "evaluation-operator", permissions: ["schedule"],
      effective_at: "2026-09-01T12:40:00Z", commit_id: "evaluation-commit")
    abort "installed live coordinator failed" unless result.rejection_reason.nil? && result.state["schedule_revision"] == 1
    replayed = RBBB::LiveScheduling::Projector.apply(snapshot: snapshot, configurations: coordinator_args[:configurations], records: result.records)
    abort "installed edit replay differs" unless replayed == result.state
    coordinator = RBBB::LiveScheduling::Coordinator.new(**coordinator_args, snapshot: result.state)
    linked = coordinator.bid(unit_id: "c", command: {"type" => "place_bid", "command_id" => "linked-bid",
      "bidder_id" => "evaluation-second-bidder", "maximum_minor_units" => 3000},
      effective_at: "2026-09-01T13:09:50Z", commit_id: "linked-commit")
    abort "installed linked bid failed" unless linked.rejection_reason.nil? &&
      linked.state["units"].values.all? { |unit| unit["closes_at"] == "2026-09-01T13:12:50Z" }
    abort "installed extension replay differs" unless RBBB::LiveScheduling::Projector.apply(
      snapshot: result.state, configurations: coordinator_args[:configurations], records: linked.records) == linked.state
    coordinator = RBBB::LiveScheduling::Coordinator.new(**coordinator_args, snapshot: linked.state)
    close_command = {"type" => "close_bidding", "command_id" => "linked-close"}
    early = coordinator.close(group_id: "evaluation-group", command: close_command,
      effective_at: "2026-09-01T13:10:00Z", commit_id: "early-close")
    abort "installed group closed at old deadline" unless early.rejection_reason && early.records.empty?
    closed = coordinator.close(group_id: "evaluation-group", command: close_command,
      effective_at: "2026-09-01T13:12:50Z", commit_id: "closed-commit")
    abort "installed atomic close failed" unless closed.rejection_reason.nil? &&
      closed.state["units"].values.all? { |unit| unit["status"] == "closed" && unit["winning_minor_units"] == 1000 }
    abort "installed close replay differs" unless RBBB::LiveScheduling::Projector.apply(
      snapshot: linked.state, configurations: coordinator_args[:configurations], records: closed.records) == closed.state

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

  puts "Verified #{gem_path.basename}: #{extracted_files.length} files, clean install, baseline bid and linked edit/extension/close/replay."
end
