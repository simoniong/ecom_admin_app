class CarrierChangeJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  BATCH_SIZE = 40

  def perform(company_id, fulfillment_ids, carrier_code)
    company = Company.find_by(id: company_id)
    return unless company&.tracking_enabled?
    return if company.tracking_api_key.blank?

    fulfillments = scoped_fulfillments(company, fulfillment_ids)
    return if fulfillments.empty?

    service = TrackingService.new(api_key: company.tracking_api_key)
    groups = fulfillments.group_by(&:tracking_number)

    groups.keys.each_slice(BATCH_SIZE) do |numbers|
      result = service.change_carrier(numbers, carrier_new: carrier_code)
      applied = result[:accepted].dup

      if result[:rejected].any?
        rejected_numbers = result[:rejected].map { |r| r[:number] }
        Rails.logger.warn("[CarrierChange] changecarrier rejected #{rejected_numbers.inspect}; registering with carrier #{carrier_code}")
        begin
          registered = service.register(rejected_numbers, carrier: carrier_code, auto_detection: false)
          applied.concat(Array(registered).map { |entry| entry["number"] })
        rescue StandardError => e
          Rails.logger.warn("[CarrierChange] register fallback failed for #{rejected_numbers.inspect}: #{e.message}")
        end
      end

      ids = applied.flat_map { |n| groups[n] || [] }.map(&:id)
      Fulfillment.where(id: ids).update_all(carrier_code: carrier_code) if ids.any?

      service.track(numbers).each do |res|
        Array(groups[res[:tracking_number]]).each { |f| f.update_from_tracking_result(res) }
      end
    end
  end

  private

  def scoped_fulfillments(company, ids)
    store_ids = company.shopify_stores.select(:id)
    Fulfillment.with_tracking
               .where(id: ids)
               .joins(:order)
               .where(orders: { shopify_store_id: store_ids })
               .to_a
  end
end
