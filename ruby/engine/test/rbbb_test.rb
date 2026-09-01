# frozen_string_literal: true

require_relative "test_helper"

class RBBBTest < Minitest::Test
  def test_has_a_version
    refute_nil RBBB::VERSION
  end

  def test_scaffold_fails_closed
    error = assert_raises(RBBB::NotImplemented) { RBBB.decide({}, {}) }

    assert_includes error.message, "do not use RBBB for live bids"
  end
end
