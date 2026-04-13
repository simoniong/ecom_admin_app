class EmailWorkflow < ApplicationRecord
  belongs_to :shopify_store
  has_many :email_workflow_steps, -> { order(position: :asc) }, dependent: :destroy
  has_many :email_workflow_runs, dependent: :destroy

  accepts_nested_attributes_for :email_workflow_steps, allow_destroy: true

  TRIGGER_EVENTS = %w[order_placed order_shipped order_delivered].freeze

  validates :trigger_event, presence: true, inclusion: { in: TRIGGER_EVENTS }
  validates :trigger_event, uniqueness: { scope: :shopify_store_id }

  scope :enabled, -> { where(enabled: true) }

  def trigger_event_display
    trigger_event&.titleize
  end
end
