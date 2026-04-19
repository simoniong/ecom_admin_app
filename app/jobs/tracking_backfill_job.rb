class TrackingBackfillJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 40

  def perform
    Company.tracking_active.find_each do |company|
      backfill_for_company(company)
    end
  end

  private

  def backfill_for_company(company)
    fulfillments = Fulfillment.with_tracking.where(tracking_status: nil)
      .joins(:order)
      .where(orders: { shopify_store_id: company.shopify_stores.select(:id) })
    fulfillments = fulfillments.where("orders.ordered_at >= ?", company.tracking_starts_at) if company.tracking_starts_at
    return if fulfillments.empty?

    service = TrackingService.new(api_key: company.tracking_api_key)
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
    Rails.logger.error("[TrackingBackfill] Company #{company.id} failed: #{e.message}")
  end
end
