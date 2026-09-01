# frozen_string_literal: true

require_relative "test_helper"

class IncrementScheduleTest < Minitest::Test
  def setup
    @schedule = RBBB::IncrementSchedule.new([
      {from_minor_units: 0, amount_minor_units: 1_000},
      {from_minor_units: 100_000, amount_minor_units: 2_500}
    ])
  end

  def test_uses_inclusive_lower_bound
    assert_equal 1_000, @schedule.increment_for(99_999)
    assert_equal 2_500, @schedule.increment_for(100_000)
  end

  def test_sorts_tiers_before_lookup
    schedule = RBBB::IncrementSchedule.new([
      {from_minor_units: 100_000, amount_minor_units: 2_500},
      {from_minor_units: 0, amount_minor_units: 1_000}
    ])

    assert_equal 2_500, schedule.increment_for(150_000)
  end

  def test_requires_zero_lower_bound
    assert_raises(RBBB::InvalidConfiguration) do
      RBBB::IncrementSchedule.new([
        {from_minor_units: 100, amount_minor_units: 10}
      ])
    end
  end

  def test_rejects_duplicate_lower_bounds
    assert_raises(RBBB::InvalidConfiguration) do
      RBBB::IncrementSchedule.new([
        {from_minor_units: 0, amount_minor_units: 10},
        {from_minor_units: 0, amount_minor_units: 20}
      ])
    end
  end
end
