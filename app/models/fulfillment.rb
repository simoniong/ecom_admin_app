class Fulfillment < ApplicationRecord
  belongs_to :order

  validates :shopify_fulfillment_id, presence: true, uniqueness: true

  TRACKING_STATUSES = %w[NotFound InfoReceived InTransit AvailableForPickup OutForDelivery DeliveryFailure Delivered Exception Expired].freeze

  # Display names for UI (camelCase → human readable)
  STATUS_DISPLAY_NAMES = {
    "NotFound" => "Not Found",
    "InfoReceived" => "Info Received",
    "InTransit" => "In Transit",
    "AvailableForPickup" => "Pick Up",
    "OutForDelivery" => "Out for Delivery",
    "DeliveryFailure" => "Undelivered",
    "Delivered" => "Delivered",
    "Exception" => "Alert",
    "Expired" => "Expired"
  }.freeze

  STATUS_COLORS = {
    "NotFound" => "bg-gray-100 text-gray-600",
    "InfoReceived" => "bg-cyan-100 text-cyan-800",
    "InTransit" => "bg-blue-100 text-blue-800",
    "AvailableForPickup" => "bg-indigo-100 text-indigo-800",
    "OutForDelivery" => "bg-violet-100 text-violet-800",
    "DeliveryFailure" => "bg-orange-100 text-orange-800",
    "Delivered" => "bg-green-100 text-green-800",
    "Exception" => "bg-red-100 text-red-800",
    "Expired" => "bg-gray-100 text-gray-500"
  }.freeze

  STATUS_DOT_COLORS = {
    "NotFound" => "bg-gray-400",
    "InfoReceived" => "bg-cyan-500",
    "InTransit" => "bg-blue-500",
    "AvailableForPickup" => "bg-indigo-500",
    "OutForDelivery" => "bg-violet-500",
    "DeliveryFailure" => "bg-orange-500",
    "Delivered" => "bg-green-500",
    "Exception" => "bg-red-500",
    "Expired" => "bg-gray-400"
  }.freeze

  scope :with_tracking, -> { where.not(tracking_number: [ nil, "" ]) }
  scope :non_terminal, -> { where(tracking_status: [ nil, "" ]).or(where.not(tracking_status: %w[Delivered Expired])) }
  scope :by_tracking_status, ->(status) { where(tracking_status: status) }
  scope :by_destination, ->(country) { where(destination_country: country) }
  scope :by_origin_carrier, ->(carrier) { where(origin_carrier: carrier) }
  scope :by_destination_carrier, ->(carrier) { where(destination_carrier: carrier) }
  scope :by_store, ->(store_id) { joins(:order).where(orders: { shopify_store_id: store_id }) }
  scope :by_shipped_between, ->(from, to) { where(shipped_at: from..to) }
  scope :by_delivered_between, ->(from, to) { where(delivered_at: from..to) }
  scope :by_last_event_between, ->(from, to) { where(last_event_at: from..to) }
  scope :by_ordered_between, ->(from, to) { joins(:order).where(orders: { ordered_at: from..to }) }

  scope :search_by, ->(query) {
    left_joins(order: :customer).where(
      "fulfillments.tracking_number ILIKE :q OR orders.name ILIKE :q OR orders.email ILIKE :q OR customers.email ILIKE :q",
      q: "%#{sanitize_sql_like(query)}%"
    )
  }

  after_commit :register_tracking, if: :should_register_tracking?

  def status_badge_classes
    STATUS_COLORS[tracking_status] || "bg-gray-100 text-gray-600"
  end

  def status_dot_class
    STATUS_DOT_COLORS[tracking_status] || "bg-gray-400"
  end

  def tracking_status_display
    return tracking_status if tracking_status.blank?

    STATUS_DISPLAY_NAMES[tracking_status] || tracking_status.gsub(/([a-z])([A-Z])/, '\1 \2')
  end

  def update_from_tracking_result(result)
    update!(
      tracking_status: result[:status],
      tracking_sub_status: result[:sub_status],
      origin_country: result[:origin_country],
      destination_country: result[:destination_country],
      origin_carrier: result[:origin_carrier],
      destination_carrier: result[:destination_carrier],
      transit_days: result[:transit_days],
      last_event_at: result[:last_event_time].present? ? Time.zone.parse(result[:last_event_time]) : nil,
      latest_event_description: result[:last_event],
      shipped_at: extract_shipped_at(result),
      delivered_at: extract_delivered_at(result),
      tracking_details: result
    )
  end

  def shopify_shipped_at
    created_at_str = shopify_data&.dig("created_at")
    return nil unless created_at_str.present?

    Time.zone.parse(created_at_str)
  rescue ArgumentError
    nil
  end

  def last_tracking_event
    latest_event_description || tracking_details&.dig("last_event")
  end

  def last_tracking_time
    last_event_at&.iso8601 || tracking_details&.dig("last_event_time")
  end

  def tracking_events
    (tracking_details&.dig("events") || []).sort_by { |e| Time.zone.parse(e["time"]) rescue Time.at(0) }.reverse
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

  def extract_shipped_at(result)
    events = result[:events] || []
    first_transit = events.find { |e| e[:description]&.match?(/in transit|collected|depart|picked up/i) }
    extracted = first_transit ? (Time.zone.parse(first_transit[:time]) rescue nil) : nil
    extracted || shipped_at
  end

  def extract_delivered_at(result)
    return delivered_at unless result[:status] == "Delivered"
    return delivered_at unless result[:last_event_time].present?

    Time.zone.parse(result[:last_event_time]) rescue delivered_at
  end
end
