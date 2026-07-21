class CreatePackages < ActiveRecord::Migration[8.1]
  def change
    create_table :packages, id: :uuid do |t|
      t.references :shopify_store, type: :uuid, null: false, foreign_key: true
      t.references :order, type: :uuid, null: false, foreign_key: true, index: false
      t.references :logistics_channel, type: :uuid, null: true, foreign_key: true
      t.string  :aasm_state, null: false
      t.string  :application_status, null: false, default: "none"
      t.string  :held_from
      t.integer :number, null: false
      t.text    :note
      t.timestamps
    end
    add_index :packages, :order_id, unique: true, name: "index_packages_on_order_id_unique"
    add_index :packages, [ :shopify_store_id, :number ], unique: true
    add_index :packages, [ :shopify_store_id, :aasm_state ]
  end
end
