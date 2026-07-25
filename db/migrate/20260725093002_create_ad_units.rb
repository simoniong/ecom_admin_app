class CreateAdUnits < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_units, id: :uuid do |t|
      t.references :ad_account, null: false, foreign_key: true, type: :uuid
      t.references :ad_creative, null: true, foreign_key: true, type: :uuid
      t.references :ad_campaign, null: true, foreign_key: true, type: :uuid
      t.string :ad_id, null: false
      t.string :ad_name
      t.string :adset_id
      t.string :status, default: "active", null: false
      t.boolean :multi_asset, default: false, null: false

      t.timestamps
    end

    add_index :ad_units, [ :ad_account_id, :ad_id ], unique: true
  end
end
