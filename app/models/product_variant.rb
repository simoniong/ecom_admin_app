class ProductVariant < ApplicationRecord
  belongs_to :product
  has_one  :shopify_store, through: :product
  has_many :order_line_items, dependent: :nullify

  validates :shopify_variant_id, presence: true
  validates :unit_cost,    numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weight_grams, numericality: { greater_than: 0,            allow_nil: true }
  validates :packaging_cost, numericality: { greater_than_or_equal_to: 0 }
end
