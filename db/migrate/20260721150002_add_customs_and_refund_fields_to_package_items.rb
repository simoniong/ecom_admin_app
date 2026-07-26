class AddCustomsAndRefundFieldsToPackageItems < ActiveRecord::Migration[8.1]
  def change
    # Per-item customs snapshot copied from the product_variant at build time,
    # smart-refreshed on re-sync unless customs_overridden (2B-2's customs edit
    # sets it). refunded_quantity tracks how many units Shopify refunded/cancelled
    # so the packer sees "do not ship".
    add_column :package_items, :customs_name_zh, :string
    add_column :package_items, :customs_name_en, :string
    add_column :package_items, :declared_value_usd, :decimal, precision: 10, scale: 2
    add_column :package_items, :hs_code, :string
    add_column :package_items, :import_hs_code, :string
    add_column :package_items, :customs_weight_grams, :decimal, precision: 12, scale: 3
    add_column :package_items, :customs_overridden, :boolean, null: false, default: false
    add_column :package_items, :refunded_quantity, :integer, null: false, default: 0
  end
end
