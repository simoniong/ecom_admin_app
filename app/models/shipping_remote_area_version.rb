class ShippingRemoteAreaVersion < ApplicationRecord
  belongs_to :company
  has_many :rules, class_name: "ShippingRemoteAreaRule",
                   foreign_key: :version_id, dependent: :destroy, inverse_of: :version

  validates :name, :country_code, :effective_from, presence: true
  validate :effective_to_after_from

  scope :for_lookup, ->(country:, on_date:) {
    where(country_code: country)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }

  def self.lookup(company:, country:, on_date:)
    where(company: company).for_lookup(country: country, on_date: on_date).first
  end

  # The matching rule for a normalized postal key, most specific first
  # (highest postal_start), mirroring ShippingZonePostalRule#zone_for.
  def surcharge_for(key)
    rules.where("postal_start <= :k AND postal_end >= :k", k: key)
         .order(postal_start: :desc).first
  end

  private

  def effective_to_after_from
    return unless effective_from && effective_to
    errors.add(:effective_to, "must be on or after effective_from") if effective_to < effective_from
  end
end
