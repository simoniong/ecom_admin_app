class AddNameToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :name, :string
  end
end
