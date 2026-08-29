class AddQuantitySnapshotToOrderLineItems < ActiveRecord::Migration[8.1]
  # The quantity this line should be PRICED at, as opposed to `quantity`, which
  # is what Shopify says was originally ordered and never moves.
  #
  # Shopify never drops a removed item from an order's line_items; it leaves the
  # row and sets current_quantity to 0. Pricing `quantity` therefore weighs
  # goods that were pulled from the order before it shipped. But current_quantity
  # ALSO goes to 0 on a refund long after delivery, where the parcel really did
  # carry the goods — on staging 138 of 185 zeroed lines are that case, so
  # following current_quantity blindly would rewrite more history than it fixed.
  #
  # So the snapshot is written while the order is unshipped and frozen once it
  # is fulfilled. Nullable: existing rows read through to `quantity`, which is
  # exactly today's behaviour, so nothing moves until a sync fills it in.
  def change
    add_column :order_line_items, :quantity_snapshot, :integer
  end
end
