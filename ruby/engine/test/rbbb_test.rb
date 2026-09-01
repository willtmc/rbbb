# frozen_string_literal: true

require_relative "test_helper"

class RBBBTest < Minitest::Test
  def test_has_a_version
    refute_nil RBBB::VERSION
  end
end
