class AddDefaultServiceTypeToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :default_service_type, :string
  end
end
