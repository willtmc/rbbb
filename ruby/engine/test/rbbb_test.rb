# frozen_string_literal: true

require_relative "test_helper"

class RBBBTest < Minitest::Test
  def test_exposes_evaluation_compatibility_metadata
    assert_equal "0.1.0.pre.1", RBBB::VERSION
    assert_equal "0.1.0-draft", RBBB::SPECIFICATION_VERSION
    assert_equal "experimental", RBBB::RELEASE_STATUS
  end
end
