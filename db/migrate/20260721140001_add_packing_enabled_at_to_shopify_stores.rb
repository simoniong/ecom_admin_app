class AddPackingEnabledAtToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :packing_enabled_at, :datetime
  end
end
