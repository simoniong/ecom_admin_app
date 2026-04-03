class Order < ApplicationRecord
  belongs_to :customer
  belongs_to :shopify_store, optional: true
  has_many :fulfillments, dependent: :destroy

  validates :shopify_order_id, presence: true, uniqueness: { scope: :shopify_store_id }

  scope :by_recency, -> { order(ordered_at: :desc) }
  scope :ordered_between, ->(from, to) { where(ordered_at: from..to) }
  scope :search_by, ->(query) {
    joins(:customer).where(
      "orders.email ILIKE :q OR orders.name ILIKE :q OR customers.first_name ILIKE :q OR customers.last_name ILIKE :q OR CONCAT(customers.first_name, ' ', customers.last_name) ILIKE :q",
      q: "%#{sanitize_sql_like(query)}%"
    )
  }
  scope :by_financial_status, ->(status) { where(financial_status: status) }
  scope :by_fulfillment_status, ->(status) { where(fulfillment_status: status) }
end
