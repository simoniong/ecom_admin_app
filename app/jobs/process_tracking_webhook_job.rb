class ProcessTrackingWebhookJob < ApplicationJob
  queue_as :default

  def perform(payload)
    tracking_number = payload["number"] || payload.dig("data", "number")
    return if tracking_number.blank?

    fulfillments = Fulfillment.where(tracking_number: tracking_number)
    return if fulfillments.empty?

    results = TrackingService.new.track([ tracking_number ])
    result = results.find { |r| r[:tracking_number] == tracking_number }
    return unless result

    fulfillments.find_each do |fulfillment|
      fulfillment.update_from_tracking_result(result)
    end
  rescue => e
    Rails.logger.error("[TrackingWebhook] Failed for #{tracking_number}: #{e.message}")
  end
end
