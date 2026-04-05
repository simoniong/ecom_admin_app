class ShopifyLookupRetryJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(ticket_id)
    ticket = Ticket.find_by(id: ticket_id)
    return unless ticket
    return if ticket.customer_id.present?

    ShopifyLookupService.new.lookup(ticket)
  end
end
