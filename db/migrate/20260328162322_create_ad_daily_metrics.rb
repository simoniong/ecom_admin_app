class CreateAdDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_daily_metrics, id: :uuid do |t|
      t.references :ad_account, null: false, foreign_key: true, type: :uuid
      t.date :date, null: false
      t.decimal :spend, precision: 12, scale: 2, default: 0
      t.integer :impressions, default: 0
      t.integer :clicks, default: 0
      t.integer :conversions, default: 0
      t.decimal :conversion_value, precision: 12, scale: 2, default: 0

      t.timestamps
    end

    add_index :ad_daily_metrics, [ :ad_account_id, :date ], unique: true
  end
end
