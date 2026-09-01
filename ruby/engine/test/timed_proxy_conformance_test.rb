# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/conformance_runner"

class TimedProxyConformanceTest < Minitest::Test
  SCENARIOS = %w[
    001-first-maximum-opens-at-opening.yaml
    002-maximum-below-opening-rejected.yaml
    003-proxy-advances-one-increment.yaml
    004-earlier-equal-maximum-retains-priority.yaml
    005-tier-selected-from-losing-maximum.yaml
    006-proxy-clipping-permits-short-increment.yaml
    007-challenger-below-next-required-rejected.yaml
    008-leader-may-raise-by-less-than-increment.yaml
    009-reserve-pushes-price-without-being-met.yaml
    010-real-bidder-wins-reserve-tie.yaml
    011-maximum-above-reserve-stops-at-reserve.yaml
    012-qualifying-bid-resets-soft-close.yaml
    013-private-maximum-raise-does-not-extend.yaml
    014-bid-at-closing-time-rejected.yaml
    015-bid-ordered-before-close-remains-eligible.yaml
    016-bidder-reduces-unexecuted-proxy.yaml
    017-reduction-below-executed-amount-rejected.yaml
    018-command-order-controls-reduction-floor.yaml
    019-operator-void-recomputes-standing-state.yaml
  ].freeze

  SCENARIOS.each do |filename|
    define_method("test_#{File.basename(filename, '.yaml').tr('-', '_')}") do
      ConformanceRunner.new(self).run(
        "conformance/scenarios/timed-proxy/#{filename}"
      )
    end
  end
end
