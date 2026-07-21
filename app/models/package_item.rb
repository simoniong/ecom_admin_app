class PackageItem < ApplicationRecord
  belongs_to :package
  belongs_to :product_variant, optional: true
  belongs_to :order_line_item, optional: true

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
end
