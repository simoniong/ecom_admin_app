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
    by_number = fulfillments.index_by(&:tracking_number)

    by_number.keys.each_slice(BATCH_SIZE) do |numbers|
      result = service.change_carrier(numbers, carrier_new: carrier_code)

      if result[:rejected].any?
        retry_numbers = result[:rejected].map { |r| r[:number] }
        Rails.logger.warn("[CarrierChange] changecarrier rejected #{retry_numbers.inspect}; registering with carrier #{carrier_code}")
        service.register(retry_numbers, carrier: carrier_code, auto_detection: false)
      end

      ids = numbers.map { |n| by_number[n]&.id }.compact
      Fulfillment.where(id: ids).update_all(carrier_code: carrier_code)

      service.track(numbers).each do |res|
        by_number[res[:tracking_number]]&.update_from_tracking_result(res)
      end
    end
  end

  private

  def scoped_fulfillments(company, ids)
    store_ids = company.shopify_stores.pluck(:id)
    Fulfillment.with_tracking
               .where(id: ids)
               .joins(:order)
               .where(orders: { shopify_store_id: store_ids })
               .to_a
  end
end
