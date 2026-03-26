class Fulfillment < ApplicationRecord
  belongs_to :order

  validates :shopify_fulfillment_id, presence: true, uniqueness: true

  scope :with_tracking, -> { where.not(tracking_number: [ nil, "" ]) }

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
end
