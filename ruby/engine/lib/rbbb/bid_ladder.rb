# frozen_string_literal: true

module RBBB
  # Fixed tier-anchored rungs, with the configured opening as the first rung.
  # Each lookup visits tiers, never individual monetary steps.
  class BidLadder
    def initialize(schedule, opening)
      @tiers = schedule.tiers
      @opening = opening
      freeze
    end

    def floor(amount)
      return 0 if amount < @opening

      result = @opening
      @tiers.each_with_index do |tier, index|
        break if tier.from_minor_units > amount

        upper = [amount, (@tiers[index + 1]&.from_minor_units || Money::MAX_MINOR_UNITS + 1) - 1].min
        rung = tier.from_minor_units + ((upper - tier.from_minor_units) / tier.amount_minor_units) * tier.amount_minor_units
        result = [result, rung].max
      end
      result
    end

    def above(amount)
      return @opening if amount < @opening

      @tiers.each_with_index do |tier, index|
        candidate = if amount < tier.from_minor_units
          tier.from_minor_units
        else
          tier.from_minor_units + ((amount - tier.from_minor_units) / tier.amount_minor_units + 1) * tier.amount_minor_units
        end
        upper = (@tiers[index + 1]&.from_minor_units || Money::MAX_MINOR_UNITS + 1) - 1
        return candidate if candidate <= upper && candidate <= Money::MAX_MINOR_UNITS
      end
      nil
    end

    def ceiling(amount)
      return @opening if amount <= @opening
      return amount if floor(amount) == amount

      above(amount)
    end
  end
end
