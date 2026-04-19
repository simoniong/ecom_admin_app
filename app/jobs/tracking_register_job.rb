class TrackingRegisterJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(company_id, tracking_numbers)
    return if tracking_numbers.blank?

    company = Company.find_by(id: company_id)
    return unless company&.tracking_enabled?

    TrackingService.new(api_key: company.tracking_api_key).register(tracking_numbers)
  end
end
