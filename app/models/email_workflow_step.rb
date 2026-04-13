class EmailWorkflowStep < ApplicationRecord
  belongs_to :email_workflow

  STEP_TYPES = %w[delay send_email].freeze

  validates :step_type, presence: true, inclusion: { in: STEP_TYPES }
  validates :position, presence: true, numericality: { greater_than_or_equal_to: 0 }

  def delay?
    step_type == "delay"
  end

  def send_email?
    step_type == "send_email"
  end

  def summary
    if delay?
      delay_summary
    elsif send_email?
      instruction = config["instruction"].to_s
      instruction.truncate(60)
    end
  end

  private

  def delay_summary
    amount = config["amount"]
    unit = config["unit"] || "hours"
    parts = []
    parts << "Wait #{amount} #{unit}" if amount.present?
    parts << "until #{config['until_time']}" if config["until_time"].present?
    if config["only_days"].present?
      day_names = config["only_days"].map { |d| Date::DAYNAMES[d % 7] }
      parts << "on #{day_names.join(', ')}"
    end
    parts.join(", ")
  end
end
