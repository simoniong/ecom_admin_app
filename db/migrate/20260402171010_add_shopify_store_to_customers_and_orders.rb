class AddShopifyStoreToCustomersAndOrders < ActiveRecord::Migration[8.1]
  def change
    # Add shopify_store_id to customers
    add_reference :customers, :shopify_store, type: :uuid, null: true, foreign_key: true, index: true

    # Add shopify_store_id to orders
    add_reference :orders, :shopify_store, type: :uuid, null: true, foreign_key: true, index: true

    # Replace global unique indexes with composite (store-scoped) indexes
    remove_index :customers, :shopify_customer_id
    add_index :customers, [ :shopify_store_id, :shopify_customer_id ], unique: true,
              name: "idx_customers_store_shopify_id"

    remove_index :orders, :shopify_order_id
    add_index :orders, [ :shopify_store_id, :shopify_order_id ], unique: true,
              name: "idx_orders_store_shopify_id"
  end
end
