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
    if amount.present?
      unit_label = I18n.t("email_workflows.steps.#{unit}")
      parts << I18n.t("email_workflows.steps.wait_summary", amount: amount, unit: unit_label)
    end
    parts << I18n.t("email_workflows.steps.until_summary", time: config["until_time"]) if config["until_time"].present?
    if config["only_days"].present?
      day_names = config["only_days"].map { |d| I18n.t("email_workflows.day_names.#{%w[sun mon tue wed thu fri sat][d.to_i % 7]}") }
      parts << I18n.t("email_workflows.steps.on_days_summary", days: day_names.join(", "))
    end
    parts.join(", ")
  end
end
