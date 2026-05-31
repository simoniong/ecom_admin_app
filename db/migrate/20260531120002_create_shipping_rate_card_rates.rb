class CreateShippingRateCardRates < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_rate_card_rates, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :version_id, null: false
      t.decimal :weight_min_kg,   precision: 8,  scale: 3, null: false
      t.decimal :weight_max_kg,   precision: 8,  scale: 3, null: false
      t.decimal :per_kg_rate_cny, precision: 10, scale: 2, null: false
      t.decimal :flat_fee_cny,    precision: 10, scale: 2, default: 0, null: false
      t.timestamps
    end
    add_index :shipping_rate_card_rates, :version_id
    add_foreign_key :shipping_rate_card_rates, :shipping_rate_card_versions, column: :version_id
  end
end
