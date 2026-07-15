class CreateParcelImportBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :parcel_import_batches, id: :uuid do |t|
      t.references :shopify_store, type: :uuid, null: false, foreign_key: true
      t.references :user,          type: :uuid, null: false, foreign_key: true
      t.string   :filename
      t.jsonb    :rows,      null: false, default: []
      t.integer  :row_count, null: false, default: 0
      t.decimal  :total_cny, precision: 12, scale: 2
      t.string   :status,    null: false, default: "pending"
      t.datetime :completed_at

      t.timestamps
    end

    add_index :parcel_import_batches, [ :shopify_store_id, :status ]
  end
end
