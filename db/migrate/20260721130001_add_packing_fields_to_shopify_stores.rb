class AddPackingFieldsToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :packing_enabled, :boolean, null: false, default: false
    add_column :shopify_stores, :package_prefix, :string
    add_column :shopify_stores, :package_number_start, :integer
    add_column :shopify_stores, :package_number_seq, :integer
  end
end
