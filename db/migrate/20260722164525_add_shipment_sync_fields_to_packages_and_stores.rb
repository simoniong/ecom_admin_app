class AddShipmentSyncFieldsToPackagesAndStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :shipping_sync_enabled, :boolean, null: false, default: false

    add_column :packages, :shipped_at, :datetime
    add_column :packages, :ship_sync_status, :string, null: false, default: "none"
    add_column :packages, :ship_sync_message, :text
    add_column :packages, :carrier_marked_at, :datetime
    add_column :packages, :tracking_registered_at, :datetime
    add_column :packages, :shopify_fulfillment_id, :string

    add_index :packages, :ship_sync_status
    add_index :packages, :shopify_fulfillment_id, unique: true, where: "shopify_fulfillment_id IS NOT NULL",
              name: "index_packages_on_shopify_fulfillment_id_unique"
  end
end
