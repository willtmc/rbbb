# frozen_string_literal: true

require_relative "test_helper"

class MoneyTest < Minitest::Test
  def test_preserves_exact_minor_units
    money = RBBB::Money.new(currency: "USD", minor_units: 100_001)

    assert_equal({"currency" => "USD", "minor_units" => 100_001}, money.to_h)
  end

  def test_adds_matching_currencies
    left = RBBB::Money.new(currency: "USD", minor_units: 100)
    right = RBBB::Money.new(currency: "USD", minor_units: 25)

    assert_equal 125, (left + right).minor_units
  end

  def test_rejects_floating_point
    assert_raises(RBBB::InvalidMoney) do
      RBBB::Money.new(currency: "USD", minor_units: 10.5)
    end
  end

  def test_rejects_cross_currency_arithmetic
    usd = RBBB::Money.new(currency: "USD", minor_units: 100)
    eur = RBBB::Money.new(currency: "EUR", minor_units: 100)

    assert_raises(RBBB::InvalidMoney) { usd + eur }
  end
end
