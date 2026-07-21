class Order < ApplicationRecord
  belongs_to :customer
  belongs_to :shopify_store, optional: true
  has_many :fulfillments, dependent: :destroy
  has_many :order_line_items, dependent: :destroy
  has_many :email_workflow_runs, dependent: :destroy
  has_many :tickets, dependent: :nullify
  has_many :parcels, dependent: :nullify
  has_many :packages, dependent: :destroy

  validates :shopify_order_id, presence: true, uniqueness: { scope: :shopify_store_id }

  scope :by_recency, -> { order(ordered_at: :desc) }
  scope :ordered_between, ->(from, to) { where(ordered_at: from..to) }
  scope :search_by, ->(query) {
    joins(:customer).where(
      "orders.email ILIKE :q OR orders.name ILIKE :q OR customers.first_name ILIKE :q OR customers.last_name ILIKE :q OR CONCAT(customers.first_name, ' ', customers.last_name) ILIKE :q",
      q: "%#{sanitize_sql_like(query)}%"
    )
  }
  # Case-insensitive partial match on the order number (name), e.g. "3052" or
  # "PKS#3052". sanitize_sql_like escapes % and _ so a pasted value with those
  # characters matches literally instead of acting as a wildcard.
  scope :name_matching, ->(query) { where("orders.name ILIKE ?", "%#{sanitize_sql_like(query)}%") }
  scope :by_financial_status, ->(status) { where(financial_status: status) }
  scope :by_fulfillment_status, ->(status) { where(fulfillment_status: status) }

  # An order's destination country code resolved from shopify_data the same
  # shipping-then-billing way ShippingCostCalculator resolves the country it
  # prices against: the shipping address's country_code when it is present
  # (non-blank after trimming), else the billing address's, returning the raw
  # code of whichever address is chosen. TRIM/NULLIF mirrors Ruby's #present?.
  DESTINATION_COUNTRY_SQL =
    "CASE WHEN NULLIF(TRIM(orders.shopify_data #>> '{shipping_address,country_code}'), '') IS NOT NULL " \
    "THEN orders.shopify_data #>> '{shipping_address,country_code}' " \
    "ELSE orders.shopify_data #>> '{billing_address,country_code}' END"

  scope :with_destination_country, ->(code) { where("#{DESTINATION_COUNTRY_SQL} = ?", code) }

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

  # actual_shipping_cost is a denormalized rollup of the order's parcels. It must
  # be nil — not 0 — when there are no parcels, otherwise effective_shipping_cost
  # would treat 0 as "we know the actual cost" and stop falling back to the estimate.
  #
  # Locked: two transactions writing parcels for the same order concurrently
  # (e.g. a split shipment imported alongside an agent-API write) must not each
  # compute SUM(cost_amount) from a snapshot that can't see the other's
  # uncommitted row. with_lock forces the second caller to wait for the first
  # to commit, then recompute the sum fresh — so its update reflects both
  # parcels instead of blindly overwriting with a stale partial total.
  #
  # Explicitly FOR NO KEY UPDATE, not the default FOR UPDATE: every INSERT (or
  # order_id UPDATE) of a parcel takes an implicit FOR KEY SHARE lock on this
  # row to enforce the foreign key. FOR UPDATE conflicts with FOR KEY SHARE, so
  # two parcels written concurrently for the same order would each hold a
  # shared FK lock and then both try to upgrade to FOR UPDATE here at the same
  # time — a guaranteed deadlock (reproduced with two real connections), not
  # just a race. FOR NO KEY UPDATE is exclusive enough to serialize this method
  # against itself, while staying compatible with FOR KEY SHARE, so it never
  # has to fight the insert that triggered it.
  def refresh_actual_shipping_cost!
    with_lock("FOR NO KEY UPDATE") do
      total = parcels.exists? ? parcels.sum(:cost_amount) : nil
      update_column(:actual_shipping_cost, total)
    end
  end

  def parcel_count
    parcels.count
  end

  def shipping_variance
    return nil unless actual_shipping_cost && estimated_shipping_cost
    actual_shipping_cost - estimated_shipping_cost
  end

  def shipping_variance_pct
    return nil unless estimated_shipping_cost&.positive?
    return nil unless shipping_variance
    (shipping_variance / estimated_shipping_cost * 100).round(2)
  end
end
