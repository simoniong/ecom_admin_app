class PackageItem < ApplicationRecord
  belongs_to :package
  belongs_to :product_variant, optional: true
  belongs_to :order_line_item, optional: true

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :refunded_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def fully_refunded?
    refunded_quantity >= quantity
  end

  # The 4 customs fields required before a package can advance to tracking.
  def customs_complete?
    customs_name_zh.present? && customs_name_en.present? &&
      declared_value_usd.present? && customs_weight_grams.present?
  end
end
