class AddTimezoneToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :timezone, :string, default: "UTC", null: false
  end
end
