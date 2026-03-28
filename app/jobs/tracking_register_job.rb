class TrackingRegisterJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(tracking_numbers)
    return if tracking_numbers.blank?

    TrackingService.new.register(tracking_numbers)
  end
end
