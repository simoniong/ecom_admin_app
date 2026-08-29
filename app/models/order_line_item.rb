class OrderLineItem < ApplicationRecord
  belongs_to :order
  belongs_to :product_variant, optional: true

  validates :shopify_line_item_id, presence: true
  validates :quantity, presence: true, numericality: { greater_than: 0 }

  # The per-unit weight this line should be PRICED at: the snapshot taken when
  # the order synced, falling back to the variant's current weight for rows
  # written before the column existed (or whose variant had no weight then).
  #
  # Shipping estimates are frozen, so they have to be reproducible: reading the
  # live variant weight meant that editing a SKU silently repriced every past
  # order containing it, and the frozen figure could no longer be explained by
  # anything on the order. Every caller that weighs an order for money must go
  # through here, not through product_variant.weight_grams.
  # The quantity this line should be PRICED at. `quantity` is what Shopify says
  # was originally ordered and never moves; the snapshot is what the order still
  # contained when it last mattered — see the migration for why the two differ
  # and why following current_quantity blindly would be wrong.
  #
  # Falls back to `quantity` for rows written before the column existed, which
  # is exactly the behaviour they had.
  def shipping_quantity
    quantity_snapshot || quantity
  end

  def shipping_weight_grams
    weight_grams_snapshot || product_variant&.weight_grams
  end
end
