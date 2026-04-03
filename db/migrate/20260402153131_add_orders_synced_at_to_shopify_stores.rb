class AddOrdersSyncedAtToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :orders_synced_at, :datetime
    add_column :shopify_stores, :webhooks_registered_at, :datetime
  end
end
