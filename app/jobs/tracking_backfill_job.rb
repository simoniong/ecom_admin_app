class TrackingBackfillJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 40

  def perform
    fulfillments = Fulfillment.with_tracking.where(tracking_status: nil)
    return if fulfillments.empty?

    service = TrackingService.new
    tracking_numbers = fulfillments.pluck(:tracking_number).uniq
    results_by_number = {}

    tracking_numbers.each_slice(BATCH_SIZE) do |batch|
      service.register(batch)
      results = service.track(batch)
      results.each { |r| results_by_number[r[:tracking_number]] = r }
    end

    fulfillments.find_each do |fulfillment|
      result = results_by_number[fulfillment.tracking_number]
      next unless result

      fulfillment.update_from_tracking_result(result)
    rescue => e
      Rails.logger.error("[TrackingBackfill] Failed for #{fulfillment.tracking_number}: #{e.message}")
    end
  rescue => e
    Rails.logger.error("[TrackingBackfill] Failed: #{e.message}")
  end
end
