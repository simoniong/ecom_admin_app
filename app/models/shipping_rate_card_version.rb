class ShippingRateCardVersion < ApplicationRecord
  belongs_to :company
  has_many :rates, class_name: "ShippingRateCardRate", foreign_key: :version_id, dependent: :destroy, inverse_of: :version

  alias_attribute :country, :country_code

  validates :name, :country_code, :service_type, :effective_from, presence: true
  validate  :effective_to_after_from

  scope :for_lookup, ->(country:, service_type:, on_date:) {
    where(country_code: country, service_type: service_type)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }

  def self.lookup(company:, country:, service_type:, on_date:)
    where(company_id: company.id)
      .for_lookup(country: country, service_type: service_type, on_date: on_date)
      .first
  end

  private

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end
