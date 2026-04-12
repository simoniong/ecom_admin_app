class NotifyAgentJob < ApplicationJob
  queue_as :default

  def perform(ticket_id, notification_type, message = nil)
    ticket = Ticket.find(ticket_id)

    case notification_type
    when "new_ticket"
      DiscordWebhookService.notify_new_ticket(ticket)
    when "revise_draft"
      DiscordWebhookService.notify_revise_draft(ticket, message)
    end
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn("[NotifyAgentJob] Ticket not found: #{e.message}")
  rescue DiscordWebhookService::DeliveryError => e
    Rails.logger.error("[NotifyAgentJob] #{e.message}")
  end
end
