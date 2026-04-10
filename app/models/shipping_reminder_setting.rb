class ShippingReminderSetting < ApplicationRecord
  belongs_to :company

  FREQUENCIES = %w[every_day every_week].freeze
  DAYS_OF_WEEK = { 0 => "Sunday", 1 => "Monday", 2 => "Tuesday", 3 => "Wednesday",
                   4 => "Thursday", 5 => "Friday", 6 => "Saturday" }.freeze

  validates :timezone, presence: true
  validates :send_hour, presence: true, inclusion: { in: 0..23 }
  validates :frequency, presence: true, inclusion: { in: FREQUENCIES }
  validates :company_id, uniqueness: true
  validate :validate_recipients
  validate :validate_day_of_week_for_weekly

  def time_to_send?
    return false unless enabled?
    return false if recipients.blank?

    now_in_tz = Time.current.in_time_zone(timezone)
    return false unless now_in_tz.hour == send_hour

    if frequency == "every_week"
      return false unless now_in_tz.wday == send_day_of_week
    end

    if last_sent_at.present?
      last_in_tz = last_sent_at.in_time_zone(timezone)
      return false if last_in_tz.to_date == now_in_tz.to_date && last_in_tz.hour == now_in_tz.hour
    end

    true
  end

  private

  def validate_recipients
    return if recipients.blank?
    recipients.each do |email|
      unless email.match?(URI::MailTo::EMAIL_REGEXP)
        errors.add(:recipients, "contains invalid email: #{email}")
      end
    end
  end

  def validate_day_of_week_for_weekly
    if frequency == "every_week" && send_day_of_week.nil?
      errors.add(:send_day_of_week, "is required for weekly frequency")
    end
  end
end
