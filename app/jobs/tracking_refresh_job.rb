class TrackingRefreshJob < ApplicationJob
  queue_as :default

  def perform
    fulfillments = Fulfillment.with_tracking
    return if fulfillments.empty?

    tracking_numbers = fulfillments.pluck(:tracking_number).uniq
    results = TrackingService.new.track(tracking_numbers)

    results_by_number = results.index_by { |r| r[:tracking_number] }

    fulfillments.find_each do |fulfillment|
      result = results_by_number[fulfillment.tracking_number]
      next unless result

      fulfillment.update!(tracking_details: result)
    end
  rescue => e
    Rails.logger.error("[TrackingRefresh] Failed: #{e.message}")
  end
end
