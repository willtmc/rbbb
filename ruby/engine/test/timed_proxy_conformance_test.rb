# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/conformance_runner"

class TimedProxyConformanceTest < Minitest::Test
  SCENARIOS = Dir.children(File.expand_path("../../../conformance/scenarios/timed-proxy", __dir__))
    .select { |name| name.end_with?(".yaml") }.sort.freeze

  SCENARIOS.each do |filename|
    define_method("test_#{File.basename(filename, '.yaml').tr('-', '_')}") do
      ConformanceRunner.new(self).run(
        "conformance/scenarios/timed-proxy/#{filename}"
      )
    end
  end
end
