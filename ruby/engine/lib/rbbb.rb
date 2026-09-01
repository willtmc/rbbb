# frozen_string_literal: true

require_relative "rbbb/version"

# Namespace for the R Triple B Ruby reference implementation.
module RBBB
  class Error < StandardError; end
  class InvalidConfiguration < Error; end
  class InvalidMoney < Error; end
  class InvalidState < Error; end
  class UnsupportedFeature < Error; end
end

require_relative "rbbb/money"
require_relative "rbbb/increment_schedule"
require_relative "rbbb/timestamp"
require_relative "rbbb/configuration"
require_relative "rbbb/event"
require_relative "rbbb/decision"
require_relative "rbbb/state"
require_relative "rbbb/engine"
