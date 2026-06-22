class Order < ApplicationRecord
  belongs_to :customer
  belongs_to :shopify_store, optional: true
  has_many :fulfillments, dependent: :destroy
  has_many :order_line_items, dependent: :destroy
  has_many :email_workflow_runs, dependent: :destroy
  has_many :tickets, dependent: :nullify

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

  def cogs_total
    order_line_items.sum("quantity * COALESCE(unit_cost_snapshot, 0)")
  end

  def gross_profit
    return nil unless total_price
    total_price - cogs_total
  end

  def gross_margin_pct
    return nil unless total_price && total_price.positive?
    (gross_profit / total_price * 100).round(2)
  end

  def cogs_complete?
    !order_line_items.where(unit_cost_snapshot: nil).exists?
  end

  def effective_shipping_cost
    actual_shipping_cost || estimated_shipping_cost
  end

  def net_profit_per_order
    return nil unless total_price
    total_price - cogs_total - (effective_shipping_cost || 0)
  end

  def shipping_complete?
    effective_shipping_cost.present?
  end

  def shipping_is_actual?
    actual_shipping_cost.present?
  end
end
