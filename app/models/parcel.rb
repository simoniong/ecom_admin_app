class Parcel < ApplicationRecord
  belongs_to :shopify_store
  belongs_to :order, optional: true

  validates :identifier, presence: true,
                         uniqueness: { scope: :shopify_store_id }

  scope :unmatched, -> { where(order_id: nil) }

  after_save    :refresh_order_rollups
  after_destroy :refresh_order_rollups

  private

  # A parcel can move between orders (e.g. an unmatched parcel gets assigned).
  # Both the old and the new order must be recalculated, otherwise the old one
  # keeps a stale actual_shipping_cost that no longer has any parcels backing it.
  def refresh_order_rollups
    ids = [ order_id, order_id_previously_was ].compact.uniq
    Order.where(id: ids).find_each(&:refresh_actual_shipping_cost!)
  end
end
