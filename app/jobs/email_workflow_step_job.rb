class EmailWorkflowStepJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    run = EmailWorkflowRun.find_by(id: run_id)
    return unless run&.running?

    if customer_replied_since?(run)
      run.cancel!("customer_replied")
      return
    end

    unless run.email_workflow.enabled?
      run.cancel!("workflow_disabled")
      return
    end

    step = run.email_workflow.email_workflow_steps.find_by(position: run.current_step_position)

    unless step
      run.complete!
      return
    end

    case step.step_type
    when "delay"
      execute_delay(run, step)
    when "send_email"
      execute_send_email(run, step)
      advance_to_next_step(run)
    end
  end

  private

  def customer_replied_since?(run)
    ticket = run.ticket
    account_email = ticket.email_account.email
    ticket.messages
      .where("sent_at > ?", run.started_at)
      .where.not("\"from\" ILIKE ?", "%#{account_email}%")
      .exists?
  end

  def execute_delay(run, step)
    delay_seconds = calculate_delay(run, step)
    run.update!(
      current_step_position: run.current_step_position + 1,
      scheduled_job_id: nil
    )
    job = self.class.set(wait: delay_seconds.seconds).perform_later(run.id)
    run.update!(scheduled_job_id: job.job_id)
  end

  def execute_send_email(run, step)
    ticket = run.ticket
    instruction = step.config["instruction"]

    trigger_event = run.email_workflow.trigger_event
    ticket.update!(status: :new_ticket, reopened_reason: trigger_event, draft_reply: nil, draft_reply_at: nil)

    DiscordWebhookService.notify_workflow_action(ticket, instruction)
  end

  def advance_to_next_step(run)
    next_position = run.current_step_position + 1
    next_step = run.email_workflow.email_workflow_steps.find_by(position: next_position)

    if next_step
      run.update!(current_step_position: next_position, scheduled_job_id: nil)
      self.class.perform_later(run.id)
    else
      run.complete!
    end
  end

  def calculate_delay(run, step)
    config = step.config
    amount = config["amount"].to_i
    unit = config["unit"] || "hours"
    base_delay = unit == "days" ? amount.days : amount.hours

    target_time = Time.current + base_delay
    store = run.email_workflow.shopify_store
    tz = store.active_timezone

    if config["until_time"].present?
      hour, min = config["until_time"].split(":").map(&:to_i)
      target_in_tz = target_time.in_time_zone(tz)
      candidate = target_in_tz.change(hour: hour, min: min)
      candidate += 1.day if candidate <= target_in_tz
      target_time = candidate.utc
    end

    if config["only_days"].present?
      allowed = config["only_days"].map(&:to_i)
      target_in_tz = target_time.in_time_zone(tz)
      7.times do
        break if allowed.include?(target_in_tz.wday)
        target_in_tz += 1.day
      end
      target_time = target_in_tz.utc
    end

    [ target_time - Time.current, 0 ].max.to_i
  end
end
