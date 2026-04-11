class EmailScheduler
  MIN_DELAY = 5.minutes

  def self.schedule!(ticket)
    new(ticket).schedule!
  end

  def self.cancel!(ticket)
    new(ticket).cancel!
  end

  def initialize(ticket)
    @ticket = ticket
    @email_account = ticket.email_account
  end

  def schedule!
    send_at = calculate_send_time
    job = SendScheduledEmailJob.set(wait_until: send_at).perform_later(@ticket.id)

    @ticket.update!(
      scheduled_send_at: send_at,
      scheduled_job_id: job.job_id
    )
  end

  def cancel!
    if @ticket.scheduled_job_id.present?
      SolidQueue::Job.find_by(active_job_id: @ticket.scheduled_job_id)&.destroy
    end

    @ticket.update!(
      scheduled_send_at: nil,
      scheduled_job_id: nil
    )
  end

  private

  def calculate_send_time
    timezone = customer_timezone
    now = Time.current
    earliest = now + MIN_DELAY

    earliest_in_tz = earliest.in_time_zone(timezone)

    if in_send_window?(earliest_in_tz)
      earliest
    elsif before_send_window?(earliest_in_tz)
      earliest_in_tz.change(hour: window_from_hour, min: window_from_minute, sec: 0).utc
    else
      (earliest_in_tz + 1.day).change(hour: window_from_hour, min: window_from_minute, sec: 0).utc
    end
  end

  def in_send_window?(time)
    minutes = time.hour * 60 + time.min
    minutes >= window_from && minutes < window_to
  end

  def before_send_window?(time)
    minutes = time.hour * 60 + time.min
    minutes < window_from
  end

  def window_from_hour
    @email_account.send_window_from_hour
  end

  def window_from_minute
    @email_account.send_window_from_minute
  end

  def window_from
    @email_account.send_window_from
  end

  def window_to
    @email_account.send_window_to
  end

  def customer_timezone
    @ticket.customer&.timezone || "America/New_York"
  end
end
