class EmailWorkflowRun < ApplicationRecord
  belongs_to :email_workflow
  belongs_to :order
  belongs_to :ticket

  STATUSES = %w[running completed cancelled].freeze
  CANCEL_REASONS = %w[customer_replied manual workflow_disabled].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :started_at, presence: true
  validates :cancelled_reason, inclusion: { in: CANCEL_REASONS }, allow_nil: true

  scope :running, -> { where(status: "running") }

  def running?
    status == "running"
  end

  def completed?
    status == "completed"
  end

  def cancelled?
    status == "cancelled"
  end

  def cancel!(reason)
    update!(status: "cancelled", cancelled_reason: reason, completed_at: Time.current)
  end

  def complete!
    update!(status: "completed", completed_at: Time.current, scheduled_job_id: nil)
  end
end
