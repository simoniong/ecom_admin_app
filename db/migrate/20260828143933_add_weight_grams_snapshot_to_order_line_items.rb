class AddWeightGramsSnapshotToOrderLineItems < ActiveRecord::Migration[8.1]
  # Mirrors unit_cost_snapshot: the variant attribute as it stood when the
  # order was synced, so a shipping estimate stays reproducible after someone
  # edits a SKU's weight. Nullable — rows synced before this column exists (and
  # lines whose variant had no weight at the time) fall back to the live
  # variant weight in OrderLineItem#shipping_weight_grams.
  def change
    add_column :order_line_items, :weight_grams_snapshot, :decimal, precision: 12, scale: 3
  end
end
