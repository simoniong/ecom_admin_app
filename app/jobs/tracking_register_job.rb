class TrackingRegisterJob < ApplicationJob
  queue_as :default

  def perform(tracking_numbers)
    return if tracking_numbers.blank?

    TrackingService.new.register(tracking_numbers)
  rescue => e
    Rails.logger.error("[TrackingRegister] Failed: #{e.message}")
  end
end
