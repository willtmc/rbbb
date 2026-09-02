# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# scripts/validate_documents.rb is the contract's guard against unbounded
# integers. These tests run it against a scratch copy of the repository so a
# regression in the guard itself fails the engine suite, not only CI.
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

  private

  def run_validator(root = REPO_ROOT)
    Open3.capture3(RbConfig.ruby, File.join(root, "scripts", "validate_documents.rb"))
  end

  def run_validator_with_mutation(relative_path)
    Dir.mktmpdir("rbbb-guard") do |dir|
      %w[scripts specification conformance rfcs].each do |entry|
        FileUtils.cp_r(File.join(REPO_ROOT, entry), dir)
      end
      target = File.join(dir, relative_path)
      schema = JSON.parse(File.read(target))
      yield schema
      File.write(target, JSON.pretty_generate(schema))

      _stdout, stderr, status = run_validator(dir)
      refute status.success?, "expected the validator to fail after mutating #{relative_path}"
      stderr
    end
  end
end
