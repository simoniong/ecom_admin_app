class ShippingReminderRule < ApplicationRecord
  belongs_to :company

  RULE_TYPES = %w[not_delivered without_updates ready_for_pickup tracking_stopped].freeze

  RULE_DISPLAY_NAMES = {
    "not_delivered" => "Not delivered for over X days",
    "without_updates" => "Without updates for over X days",
    "ready_for_pickup" => "Ready for Pickup for over X days",
    "tracking_stopped" => "Tracking stopped"
  }.freeze

  DEFAULT_DAYS = {
    "not_delivered" => 14,
    "without_updates" => 3,
    "ready_for_pickup" => 5
  }.freeze

  RULE_DESCRIPTIONS = {
    "not_delivered" => "have not been delivered for over",
    "without_updates" => "have not been updated for over",
    "ready_for_pickup" => "have been waiting for pickup for over",
    "tracking_stopped" => "have stopped"
  }.freeze

  validates :rule_type, presence: true, inclusion: { in: RULE_TYPES }
  validates :rule_type, uniqueness: { scope: :company_id }
  validate :validate_country_thresholds

  scope :enabled, -> { where(enabled: true) }

  def display_name
    RULE_DISPLAY_NAMES[rule_type]
  end

  def description
    RULE_DESCRIPTIONS[rule_type]
  end

  def parsed_thresholds
    (country_thresholds || []).map(&:symbolize_keys)
  end

  def matching_fulfillments(store_ids)
    if rule_type == "tracking_stopped"
      countries = parsed_thresholds.map { |t| t[:country] }
      return [] if countries.empty?
      query_tracking_stopped(countries, store_ids)
    else
      parsed_thresholds.flat_map do |threshold|
        query_for_threshold(threshold[:country], threshold[:days].to_i, store_ids)
      end.uniq(&:id)
    end
  end

  private

  def validate_country_thresholds
    return if country_thresholds.blank?
    unless country_thresholds.is_a?(Array) &&
           country_thresholds.all? { |ct| valid_threshold?(ct) }
      errors.add(:country_thresholds, "must be an array of valid threshold objects")
    end
  end

  def valid_threshold?(ct)
    return false unless ct.is_a?(Hash) && ct["country"].present?
    return true if rule_type == "tracking_stopped"

    ct["days"].to_i > 0
  end

  def query_tracking_stopped(countries, store_ids)
    Fulfillment.with_tracking
               .active
               .joins(:order)
               .where(orders: { shopify_store_id: store_ids })
               .where(destination_country: countries)
               .where(tracking_status: %w[Exception Expired])
               .to_a
  end

  def query_for_threshold(country, days, store_ids)
    cutoff = days.days.ago
    base = Fulfillment.with_tracking
                      .active
                      .joins(:order)
                      .where(orders: { shopify_store_id: store_ids })
                      .where(destination_country: country)

    case rule_type
    when "not_delivered"
      base.where.not(tracking_status: "Delivered")
          .where(shipped_at: ...cutoff)
          .where.not(shipped_at: nil)
    when "without_updates"
      base.non_terminal
          .where(last_event_at: ...cutoff)
          .where.not(last_event_at: nil)
    when "ready_for_pickup"
      base.where(tracking_status: "AvailableForPickup")
          .where(last_event_at: ...cutoff)
          .where.not(last_event_at: nil)
    when "tracking_stopped"
      Fulfillment.none
    else
      Fulfillment.none
    end.to_a
  end
end
