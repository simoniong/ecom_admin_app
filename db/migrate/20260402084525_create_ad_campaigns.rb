class CreateAdCampaigns < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_campaigns, id: :uuid do |t|
      t.references :ad_account, null: false, foreign_key: true, type: :uuid
      t.string :campaign_id, null: false
      t.string :campaign_name
      t.string :status, default: "active", null: false
      t.decimal :daily_budget, precision: 12, scale: 2, default: 0

      t.timestamps
    end

    add_index :ad_campaigns, [ :ad_account_id, :campaign_id ], unique: true
  end
end
