class AddSnapshotFieldsToPackages < ActiveRecord::Migration[8.1]
  def change
    # Per-package snapshot of the order's shipping address, taken at build
    # time and smart-refreshed on re-sync unless address_overridden is set
    # (2B-2's address edit sets the flag). Per-package so folding (2B-3) gives
    # each split package its own address.
    add_column :packages, :shipping_address_snapshot, :jsonb, null: false, default: {}
    add_column :packages, :address_overridden, :boolean, null: false, default: false
  end
end
