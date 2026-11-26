# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

# scripts/validate_documents.rb is the contract's guard against unbounded
# integers, version drift, malformed fixtures/scenarios, and privileged leaks.
# These tests run it against a scratch copy of the repository so a regression
# in the guard itself fails the engine suite, not only CI.
class SpecificationGuardTest < Minitest::Test
  REPO_ROOT = File.expand_path("../../..", __dir__)
  VALIDATOR = File.join(REPO_ROOT, "scripts", "validate_documents.rb")

  def setup
    skip "validator only runs from a repository checkout" unless File.file?(VALIDATOR)
  end

  def test_shared_integer_bound_matches_the_money_bound
    schema = JSON.parse(File.read(File.join(REPO_ROOT, "specification/common/integer.schema.json")))

    assert_equal RBBB::MAX_SAFE_INTEGER, schema.fetch("maximum")
    schema.fetch("$defs").each_value do |definition|
      assert_equal RBBB::MAX_SAFE_INTEGER, definition.fetch("maximum")
    end
  end

  def test_pristine_specification_passes
    stdout, stderr, status = run_validator

    assert status.success?, stderr
    assert_match(/Validated \d+ JSON Schemas/, stdout)
  end

  def test_bare_integer_property_without_maximum_fails
    stderr = run_validator_with_mutation("specification/commands/base.schema.json") do |schema|
      schema["properties"]["expected_version"] = {"type" => "integer", "minimum" => 0}
    end

    assert_match(%r{commands/base.schema.json: /properties/expected_version is an integer without a maximum}, stderr)
  end

  def test_integer_maximum_above_the_bound_fails
    stderr = run_validator_with_mutation("specification/events/base.schema.json") do |schema|
      schema["properties"]["aggregate_version"] = {
        "type" => "integer", "minimum" => 1, "maximum" => RBBB::MAX_SAFE_INTEGER + 1
      }
    end

    assert_match(%r{events/base.schema.json: /properties/aggregate_version is an integer without a maximum}, stderr)
  end

  def test_shared_integer_definition_drifting_from_the_bound_fails
    stderr = run_validator_with_mutation("specification/common/integer.schema.json") do |schema|
      schema["$defs"]["positiveInteger"]["maximum"] = 2**63 - 1
    end

    assert_match(%r{common/integer.schema.json: \$defs/positiveInteger must use the shared maximum}, stderr)
  end

  def test_fixture_missing_extension_key_fails
    stderr = run_validator_with_file_edit("conformance/fixtures/usd-standard.yaml") do |content|
      fixture = YAML.safe_load(content, aliases: false)
      fixture.delete("extension")
      YAML.dump(fixture)
    end

    assert_match(%r{conformance/fixtures/usd-standard.yaml: missing required keys: extension}, stderr)
  end

  def test_scenario_unexpected_top_level_key_fails
    stderr = run_validator_with_file_edit("conformance/scenarios/timed-proxy/001-first-maximum-opens-at-opening.yaml") do |content|
      "extra_key: true\n#{content}"
    end

    assert_match(/unexpected top-level keys: extra_key/, stderr)
  end

  def test_version_drift_fails
    stderr = run_validator_with_file_edit("specification/VERSION") { "9.9.9-draft\n" }

    assert_match(/specification\/openapi.yaml: info\.version .* does not match specification\/VERSION/, stderr)
    assert_match(/specification\/asyncapi.yaml: info\.version .* does not match specification\/VERSION/, stderr)
    assert_match(/ruby\/engine\/lib\/rbbb\/version\.rb: SPECIFICATION_VERSION .* does not match specification\/VERSION/, stderr)
  end

  def test_expanded_public_leak_denylist_catches_privileged_keys_in_public_events
    stderr = run_validator_with_file_edit("conformance/scenarios/timed-proxy/001-first-maximum-opens-at-opening.yaml") do |content|
      scenario = YAML.safe_load(content, aliases: false)
      scenario["expected"]["public_events"][0]["bidder_notice"] = nil
      YAML.dump(scenario)
    end

    assert_match(/public_events\[0\] contains privileged keys: bidder_notice/, stderr)
  end

  def test_invalid_proposal_schema_ref_fails
    stderr = run_validator_with_mutation("rfcs/proposals/flexible-live-scheduling/submission.schema.json") do |schema|
      schema["properties"]["command_id"] = {"$ref" => "contract.schema.json#/$defs/missing_def"}
    end

    assert_match(%r{rfcs/proposals/flexible-live-scheduling/submission\.schema\.json: invalid \$ref}, stderr)
  end

  private

  def run_validator(root = REPO_ROOT)
    Open3.capture3(RbConfig.ruby, File.join(root, "scripts", "validate_documents.rb"))
  end

  def run_validator_with_mutation(relative_path)
    run_validator_with_file_edit(relative_path) do |content|
      schema = JSON.parse(content)
      yield schema
      JSON.pretty_generate(schema)
    end
  end

  def run_validator_with_file_edit(relative_path)
    Dir.mktmpdir("rbbb-guard") do |dir|
      %w[scripts specification conformance rfcs].each do |entry|
        FileUtils.cp_r(File.join(REPO_ROOT, entry), dir)
      end
      version_target = File.join(dir, "ruby/engine/lib/rbbb/version.rb")
      FileUtils.mkdir_p(File.dirname(version_target))
      FileUtils.cp(File.join(REPO_ROOT, "ruby/engine/lib/rbbb/version.rb"), version_target)

      target = File.join(dir, relative_path)
      File.write(target, yield(File.read(target)))

      _stdout, stderr, status = run_validator(dir)
      refute status.success?, "expected the validator to fail after mutating #{relative_path}"
      stderr
    end
  end
end
