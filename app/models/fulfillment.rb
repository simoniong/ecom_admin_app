class Fulfillment < ApplicationRecord
  belongs_to :order

  validates :shopify_fulfillment_id, presence: true, uniqueness: true

  scope :with_tracking, -> { where.not(tracking_number: [ nil, "" ]) }

  after_commit :register_tracking, if: :should_register_tracking?

  def tracking_status
    tracking_details&.dig("status")
  end

  def last_tracking_event
    tracking_details&.dig("last_event")
  end

  def last_tracking_time
    tracking_details&.dig("last_event_time")
  end

  def tracking_events
    (tracking_details&.dig("events") || []).sort_by { |e| e["time"].to_s }.reverse
  end

  def tracking_loaded?
    tracking_details.present? && tracking_details.keys.any? { |k| k != "tracking_number" }
  end

  private

  def should_register_tracking?
    tracking_number.present? && saved_change_to_tracking_number?
  end

  def register_tracking
    TrackingRegisterJob.perform_later([ tracking_number ])
  end
end
