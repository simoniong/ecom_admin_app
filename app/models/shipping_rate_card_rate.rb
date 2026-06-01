class ShippingRateCardRate < ApplicationRecord
  belongs_to :version, class_name: "ShippingRateCardVersion", foreign_key: :version_id, inverse_of: :rates
  has_one :company, through: :version

  validates :weight_min_kg,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :weight_max_kg,   presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :per_kg_rate_cny, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :flat_fee_cny,    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate  :weight_max_greater_than_min

  scope :for_weight, ->(kg) {
    where("weight_min_kg < ? AND weight_max_kg >= ?", kg, kg)
  }

  private

  def weight_max_greater_than_min
    return unless weight_min_kg && weight_max_kg
    errors.add(:weight_max_kg, "must be greater than weight_min_kg") if weight_max_kg <= weight_min_kg
  end
end
