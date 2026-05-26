class AddProductsSyncColumnsToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :products_synced_at, :datetime
    add_column :shopify_stores, :currency, :string
  end
end
