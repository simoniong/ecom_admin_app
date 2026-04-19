class ProcessTrackingWebhookJob < ApplicationJob
  queue_as :default

  def perform(payload)
    tracking_number = payload["number"] || payload.dig("data", "number")
    return if tracking_number.blank?

    fulfillments = Fulfillment.where(tracking_number: tracking_number)
      .includes(order: { shopify_store: :company })
    return if fulfillments.empty?

    company = fulfillments
      .map { |f| f.order&.shopify_store&.company }
      .compact
      .find(&:tracking_enabled?)
    return unless company

    results = TrackingService.new(api_key: company.tracking_api_key).track([ tracking_number ])
    result = results.find { |r| r[:tracking_number] == tracking_number }
    return unless result

    fulfillments.find_each do |fulfillment|
      fulfillment.update_from_tracking_result(result)
    end
  rescue => e
    Rails.logger.error("[TrackingWebhook] Failed for #{tracking_number}: #{e.message}")
  end
end
