# frozen_string_literal: true

require_relative "rbbb/version"

# Namespace for the R Triple B Ruby reference implementation.
module RBBB
  class Error < StandardError; end

  class NotImplemented < Error; end

  # This guard prevents the scaffold from being mistaken for a bidding engine.
  def self.decide(*)
    raise NotImplemented,
      "auction behavior has not been specified; do not use RBBB for live bids"
  end
end
