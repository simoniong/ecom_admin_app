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
  validates :cost_cny,    presence: true, numericality: { greater_than: 0 }
  validates :cost_amount, presence: true, numericality: { greater_than: 0 }

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
