class ShippingRateCardVersion < ApplicationRecord
  # Canonical option values, shared by the new-version form and the store's
  # default_service_type form. Human labels are resolved via i18n
  # (shipping_rate_cards.service_types.* / shipping_rate_cards.countries.*).
  SERVICE_TYPES = %w[general with_battery].freeze
  COUNTRY_CODES = %w[US CA AU NZ GB DE NL FR].freeze

  belongs_to :company
  has_many :rates, class_name: "ShippingRateCardRate", foreign_key: :version_id, dependent: :destroy, inverse_of: :version

  validates :name, :country_code, :service_type, :effective_from, presence: true
  validates :country_code, inclusion: { in: COUNTRY_CODES }, allow_blank: true
  validates :service_type, inclusion: { in: SERVICE_TYPES }, allow_blank: true
  validate  :effective_to_after_from

  scope :for_lookup, ->(country:, service_type:, on_date:) {
    where(country_code: country, service_type: service_type)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }

  def self.lookup(company:, country:, service_type:, on_date:)
    where(company: company)
      .for_lookup(country: country, service_type: service_type, on_date: on_date)
      .first
  end

  private

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end
