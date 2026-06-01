class CreateShippingZonePostalRules < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_zone_postal_rules, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid   :company_id, null: false
      t.string :country_code, null: false
      t.string :zone, null: false
      t.string :postal_start, null: false
      t.string :postal_end, null: false
      t.timestamps
    end
    add_index :shipping_zone_postal_rules, [ :company_id, :country_code, :postal_start ],
              name: "idx_zone_postal_lookup"
    add_foreign_key :shipping_zone_postal_rules, :companies
  end
end
