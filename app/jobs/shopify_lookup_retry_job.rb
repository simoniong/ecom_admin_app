class ShopifyLookupRetryJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(ticket_id)
    ticket = Ticket.find_by(id: ticket_id)
    return unless ticket
    return if ticket.customer_id.present?
    return unless valid_email?(ticket.customer_email)

    ShopifyLookupService.new.lookup(ticket)
  end

  private

  def valid_email?(email)
    email.present? && email != "unknown" && email.include?("@")
  end
end
