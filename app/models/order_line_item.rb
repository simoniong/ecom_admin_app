class OrderLineItem < ApplicationRecord
  belongs_to :order
  belongs_to :product_variant, optional: true

  validates :shopify_line_item_id, presence: true
  validates :quantity, presence: true, numericality: { greater_than: 0 }
end
