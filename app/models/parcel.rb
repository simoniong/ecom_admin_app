class Parcel < ApplicationRecord
  belongs_to :shopify_store
  belongs_to :order, optional: true

  validates :identifier, presence: true,
                         uniqueness: { scope: :shopify_store_id }

  # cost_amount is what orders.actual_shipping_cost rolls up via SUM(). A null
  # cost_amount is silently skipped by SUM, so a parcel with no cost would make
  # money vanish from the rollup while parcels.count still looked right.
  # cost_cny is its source figure — both must be present and positive, on
  # every write path (import and the agent API alike).
  #
  # less_than: MAX_DECIMAL is the true ceiling of the decimal(10,2) columns
  # (precision 10, scale 2 → max 99999999.99). Without it, a write that
  # exceeds the column's range reaches the database and raises
  # ActiveRecord::RangeError instead of failing validation — every write path
  # rescues that for confirm_import and the agent API, but the HTML inline
  # edit (ParcelsController#update) does not, so it 500s. Bounding cost_cny
  # here turns that into an ordinary validation failure everywhere at once.
  # cost_amount is bounded the same way and independently: it's derived from
  # cost_cny / cost_fx_rate, so an in-range cost_cny paired with a very low
  # fx_rate (e.g. 0.01) can still overflow cost_amount even though cost_cny
  # itself never left range.
  MAX_DECIMAL = 10**8

  validates :cost_cny,    presence: true, numericality: { greater_than: 0, less_than: MAX_DECIMAL }
  validates :cost_amount, presence: true, numericality: { greater_than: 0, less_than: MAX_DECIMAL }

  scope :unmatched, -> { where(order_id: nil) }

  after_save    :refresh_order_rollups
  after_destroy :refresh_order_rollups

  private

  # A parcel can move between orders (e.g. an unmatched parcel gets assigned).
  # Both the old and the new order must be recalculated, otherwise the old one
  # keeps a stale actual_shipping_cost that no longer has any parcels backing it.
  def refresh_order_rollups
    ids = [ order_id, order_id_previously_was ].compact.uniq.sort
    Order.where(id: ids).order(:id).each(&:refresh_actual_shipping_cost!)
  end
end
