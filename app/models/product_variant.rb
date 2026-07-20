class ProductVariant < ApplicationRecord
  belongs_to :product
  has_one  :shopify_store, through: :product
  has_many :order_line_items, dependent: :nullify

  validates :shopify_variant_id, presence: true
  validates :unit_cost,    numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weight_grams, numericality: { greater_than: 0,            allow_nil: true }
  validates :packaging_cost, numericality: { greater_than_or_equal_to: 0 }

  CUSTOMS_REQUIRED = %i[customs_name_zh customs_name_en declared_value_usd weight_grams].freeze

  validates :customs_name_zh, :customs_name_en, presence: true, on: :customs
  validates :declared_value_usd, presence: true, numericality: { greater_than: 0 }, on: :customs
  validates :weight_grams, presence: true, on: :customs

  def customs_complete?
    customs_name_zh.present? && customs_name_en.present? &&
      declared_value_usd.present? && weight_grams.present?
  end
end
