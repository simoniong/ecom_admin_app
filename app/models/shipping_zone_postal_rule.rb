class ShippingZonePostalRule < ApplicationRecord
  belongs_to :company

  validates :country_code, :zone, :postal_start, :postal_end, presence: true
  validate  :end_not_before_start

  scope :match_for, ->(country:, key:) {
    where(country_code: country)
      .where("postal_start <= :k AND postal_end >= :k", k: key)
      .order(postal_start: :desc)
  }

  def self.zone_for(company:, country:, key:)
    where(company_id: company.id).match_for(country: country, key: key).first&.zone
  end

  def self.country_zoned?(company:, country:)
    where(company_id: company.id, country_code: country).exists?
  end

  private

  def end_not_before_start
    return unless postal_start && postal_end
    errors.add(:postal_end, "must be on or after postal_start") if postal_end < postal_start
  end
end
