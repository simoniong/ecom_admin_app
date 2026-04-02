class CreateAdCampaignDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_campaign_daily_metrics, id: :uuid do |t|
      t.references :ad_campaign, null: false, foreign_key: true, type: :uuid
      t.date :date, null: false
      t.integer :impressions, default: 0
      t.integer :clicks, default: 0
      t.integer :add_to_cart, default: 0
      t.integer :checkout_initiated, default: 0
      t.integer :purchases, default: 0
      t.decimal :spend, precision: 12, scale: 2, default: 0
      t.decimal :conversion_value, precision: 12, scale: 2, default: 0

      t.timestamps
    end

    add_index :ad_campaign_daily_metrics, [ :ad_campaign_id, :date ], unique: true, name: "idx_campaign_metrics_campaign_date"
  end
end
