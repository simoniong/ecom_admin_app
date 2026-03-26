class Order < ApplicationRecord
  belongs_to :customer
  has_many :fulfillments, dependent: :destroy

  validates :shopify_order_id, presence: true, uniqueness: true

  scope :by_recency, -> { order(ordered_at: :desc) }
end
