class CreateParcels < ActiveRecord::Migration[8.1]
  def change
    create_table :parcels, id: :uuid do |t|
      t.references :shopify_store, type: :uuid, null: false, foreign_key: true
      t.references :order,         type: :uuid, null: true,  foreign_key: true

      t.string   :identifier, null: false
      t.string   :internal_no
      t.string   :tracking_number
      t.datetime :shipped_at
      t.string   :service_channel
      t.string   :zone
      t.string   :country
      t.integer  :actual_weight_g
      t.integer  :billed_weight_g

      t.decimal :cost_cny,             precision: 10, scale: 2
      t.decimal :freight_cny,          precision: 10, scale: 2
      t.decimal :registration_fee_cny, precision: 10, scale: 2
      t.decimal :tax_cny,              precision: 10, scale: 2
      t.decimal :remote_area_fee_cny,  precision: 10, scale: 2
      t.decimal :operation_fee_cny,    precision: 10, scale: 2

      t.decimal :fx_rate_snapshot, precision: 10, scale: 4
      t.decimal :cost_amount,      precision: 10, scale: 2

      t.timestamps
    end

    add_index :parcels, [ :shopify_store_id, :identifier ], unique: true
    add_index :parcels, :tracking_number
  end
end
