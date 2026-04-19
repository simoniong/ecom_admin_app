class TrackingRefreshJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 40

  def perform
    Company.tracking_active.find_each do |company|
      refresh_for_company(company)
    end
  end

  private

  def refresh_for_company(company)
    store_ids = company.shopify_stores.pluck(:id)
    return if store_ids.empty?

    fulfillments = Fulfillment.with_tracking.non_terminal
      .joins(:order)
      .where(orders: { shopify_store_id: store_ids })
    fulfillments = fulfillments.where("orders.ordered_at >= ?", company.tracking_starts_at) if company.tracking_starts_at
    return if fulfillments.empty?

    service = TrackingService.new(api_key: company.tracking_api_key)

    unregistered = fulfillments.where(tracking_details: {}).pluck(:tracking_number).uniq
    unregistered.each_slice(BATCH_SIZE) { |batch| service.register(batch) } if unregistered.any?

    tracking_numbers = fulfillments.pluck(:tracking_number).uniq
    results_by_number = {}

    tracking_numbers.each_slice(BATCH_SIZE) do |batch|
      results = service.track(batch)
      results.each { |r| results_by_number[r[:tracking_number]] = r }
    end

    fulfillments.find_each do |fulfillment|
      result = results_by_number[fulfillment.tracking_number]
      next unless result

      fulfillment.update_from_tracking_result(result)
    end
  rescue => e
    Rails.logger.error("[TrackingRefresh] Company #{company.id} failed: #{e.message}")
  end
end
