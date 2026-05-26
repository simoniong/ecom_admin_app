class AddIndexToOrdersStoreAndOrderedAt < ActiveRecord::Migration[8.1]
  def change
    add_index :orders, [ :shopify_store_id, :ordered_at ],
              name: "idx_orders_store_ordered_at",
              if_not_exists: true
  end
end
