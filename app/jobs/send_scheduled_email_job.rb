class SendScheduledEmailJob < ApplicationJob
  queue_as :default

  def perform(ticket_id)
    ticket = Ticket.find(ticket_id)

    unless ticket.draft_confirmed?
      Rails.logger.info("[SendEmail] Ticket##{ticket_id} no longer draft_confirmed, skipping")
      return
    end

    gmail = GmailService.new(ticket.email_account)

    # Find the last customer message to reply to
    last_customer_msg = ticket.messages
      .where.not(from: ticket.email_account.email)
      .order(sent_at: :desc)
      .first

    sent_message = gmail.send_message(
      to: ticket.customer_email,
      subject: "Re: #{ticket.subject}",
      body: ticket.draft_reply,
      thread_id: ticket.gmail_thread_id,
      message_id: last_customer_msg&.gmail_message_id
    )

    # Record the sent message
    ticket.messages.create!(
      gmail_message_id: sent_message.id,
      from: ticket.email_account.email,
      to: ticket.customer_email,
      subject: "Re: #{ticket.subject}",
      body: ticket.draft_reply,
      sent_at: Time.current,
      gmail_internal_date: (Time.current.to_f * 1000).to_i
    )

    ticket.update!(
      status: :closed,
      last_message_at: Time.current,
      scheduled_send_at: nil,
      scheduled_job_id: nil
    )
  rescue => e
    Rails.logger.error("[SendEmail] Failed for Ticket##{ticket_id}: #{e.message}")
    raise
  end
end
