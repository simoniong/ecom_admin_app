class Product < ApplicationRecord
  belongs_to :shopify_store
  has_many :product_variants, dependent: :destroy

  validates :shopify_product_id, presence: true
end
