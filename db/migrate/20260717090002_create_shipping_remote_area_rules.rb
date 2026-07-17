class CreateShippingRemoteAreaRules < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_remote_area_rules, id: :uuid do |t|
      t.uuid :version_id, null: false
      t.string :postal_start, null: false
      t.string :postal_end, null: false
      t.decimal :surcharge_cny, precision: 10, scale: 2, null: false
      t.string :area_label
      t.timestamps
    end
    add_index :shipping_remote_area_rules, [ :version_id, :postal_start ],
              name: "idx_remote_area_rules_lookup"
  end
end
