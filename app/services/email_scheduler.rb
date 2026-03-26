class EmailScheduler
  SEND_WINDOW_START = 8  # 8am
  SEND_WINDOW_END = 22   # 10pm
  MIN_DELAY = 10.minutes

  def self.schedule!(ticket)
    new(ticket).schedule!
  end

  def self.cancel!(ticket)
    new(ticket).cancel!
  end

  def initialize(ticket)
    @ticket = ticket
  end

  def schedule!
    send_at = calculate_send_time
    job = SendScheduledEmailJob.set(wait_until: send_at).perform_later(@ticket.id)

    @ticket.update!(
      scheduled_send_at: send_at,
      scheduled_job_id: job.provider_job_id || job.job_id
    )
  end

  def cancel!
    if @ticket.scheduled_job_id.present?
      SolidQueue::Job.find_by(id: @ticket.scheduled_job_id)&.destroy
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

    # Convert to customer timezone to check window
    earliest_in_tz = earliest.in_time_zone(timezone)

    if in_send_window?(earliest_in_tz)
      earliest
    elsif earliest_in_tz.hour < SEND_WINDOW_START
      # Before window today — schedule for 8am today
      earliest_in_tz.change(hour: SEND_WINDOW_START, min: 0, sec: 0).utc
    else
      # After window — schedule for 8am tomorrow
      (earliest_in_tz + 1.day).change(hour: SEND_WINDOW_START, min: 0, sec: 0).utc
    end
  end

  def in_send_window?(time)
    time.hour >= SEND_WINDOW_START && time.hour < SEND_WINDOW_END
  end

  def customer_timezone
    @ticket.customer&.timezone || "UTC"
  end
end
