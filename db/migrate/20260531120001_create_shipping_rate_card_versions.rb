class CreateShippingRateCardVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_rate_card_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid   :company_id, null: false
      t.string :name, null: false
      t.string :country_code, null: false
      t.string :service_type, null: false
      t.date   :effective_from, null: false
      t.date   :effective_to
      t.timestamps
    end
    add_index :shipping_rate_card_versions,
              [ :company_id, :country_code, :service_type, :effective_from ],
              name: "idx_rate_versions_lookup"
    add_foreign_key :shipping_rate_card_versions, :companies
  end
end
