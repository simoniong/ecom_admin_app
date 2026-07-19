class SendScheduledEmailJob < ApplicationJob
  queue_as :default

  def perform(ticket_id, expected_job_id: nil)
    ticket = Ticket.find(ticket_id)

    claimed = ticket.with_lock do
      unless ticket.draft_confirmed?
        Rails.logger.info("[SendEmail] Ticket##{ticket_id} no longer draft_confirmed, skipping")
        next false
      end

      current_job_id = expected_job_id || self.job_id
      if ticket.scheduled_job_id.present? && ticket.scheduled_job_id != current_job_id
        Rails.logger.info("[SendEmail] Ticket##{ticket_id} has different scheduled_job_id, skipping stale job")
        next false
      end

      # A marker already set means a prior attempt reached the send step and did
      # not finish cleanly (hard crash) — do NOT resend; leave it for a human.
      if ticket.sending_started_at.present?
        Rails.logger.warn("[SendEmail] Ticket##{ticket_id} already claimed at #{ticket.sending_started_at}; not resending")
        next false
      end

      ticket.update!(sending_started_at: Time.current)
      true
    end
    return unless claimed

    new_thread = ticket.gmail_thread_id.blank?
    subject = new_thread ? ticket.subject.to_s : "Re: #{ticket.subject}"
    bcc = ticket.trustpilot_bcc_email.presence

    sent_message =
      begin
        GmailService.new(ticket.email_account).send_message(
          to: ticket.customer_email,
          subject: subject,
          body: ticket.draft_reply,
          thread_id: ticket.gmail_thread_id,
          bcc: bcc
        )
      rescue
        # Send did not succeed → clear the claim so this stays retryable.
        # (The outer rescue owns the error logging.)
        ticket.update_columns(sending_started_at: nil)
        raise
      end

    # Send succeeded. From here on, if a DB write fails we LEAVE the marker set
    # (the email already went out; a retry must not resend).
    ticket.messages.create!(
      gmail_message_id: sent_message.id,
      from: ticket.email_account.email,
      to: ticket.customer_email,
      bcc: bcc,
      subject: subject,
      body: ticket.draft_reply,
      sent_at: Time.current,
      gmail_internal_date: (Time.current.to_f * 1000).to_i
    )

    ticket.gmail_thread_id = sent_message.thread_id if new_thread
    ticket.assign_attributes(
      status: :closed,
      last_message_at: Time.current,
      scheduled_send_at: nil,
      scheduled_job_id: nil,
      sending_started_at: nil
    )
    ticket.save!
  rescue => e
    Rails.logger.error("[SendEmail] Failed for Ticket##{ticket_id}: #{e.message}")
    raise
  end
end
