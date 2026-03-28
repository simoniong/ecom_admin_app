class ShopifyDailyMetric < ApplicationRecord
  belongs_to :shopify_store, optional: true

  validates :date, presence: true
  validates :sessions, numericality: { greater_than_or_equal_to: 0 }
  validates :orders_count, numericality: { greater_than_or_equal_to: 0 }
  validates :revenue, numericality: { greater_than_or_equal_to: 0 }

  scope :for_date_range, ->(range) { where(date: range) }
end
