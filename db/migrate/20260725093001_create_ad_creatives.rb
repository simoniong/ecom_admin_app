class CreateAdCreatives < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_creatives, id: :uuid do |t|
      t.references :ad_account, null: false, foreign_key: true, type: :uuid
      t.string :asset_type, null: false
      t.string :asset_id, null: false
      t.string :name
      t.string :thumbnail_url
      t.integer :duration_seconds
      t.date :first_spend_date

      t.timestamps
    end

    add_index :ad_creatives, [ :ad_account_id, :asset_type, :asset_id ],
      unique: true, name: "idx_ad_creatives_on_account_type_asset"
  end
end
