class ShippingRemoteAreaRule < ApplicationRecord
  belongs_to :version, class_name: "ShippingRemoteAreaVersion", inverse_of: :rules

  validates :postal_start, :postal_end, presence: true
  validates :surcharge_cny, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :end_not_before_start

  private

  def end_not_before_start
    return unless postal_start && postal_end
    errors.add(:postal_end, "must be on or after postal_start") if postal_end < postal_start
  end
end
