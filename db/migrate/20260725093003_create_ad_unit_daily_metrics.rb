class CreateAdUnitDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_unit_daily_metrics, id: :uuid do |t|
      t.references :ad_unit, null: false, foreign_key: true, type: :uuid
      t.date :date, null: false
      t.decimal :spend, precision: 12, scale: 2, default: 0
      t.integer :impressions, default: 0
      t.integer :clicks, default: 0
      t.integer :inline_link_clicks, default: 0
      t.integer :video_continuous_2_sec_watched, default: 0
      t.integer :video_p25_watched, default: 0
      t.integer :video_p50_watched, default: 0
      t.integer :video_p75_watched, default: 0
      t.integer :video_p95_watched, default: 0
      t.integer :video_p100_watched, default: 0
      t.integer :add_to_cart, default: 0
      t.integer :checkout_initiated, default: 0
      t.integer :purchases, default: 0
      t.decimal :conversion_value, precision: 12, scale: 2, default: 0

      t.timestamps
    end

    add_index :ad_unit_daily_metrics, [ :ad_unit_id, :date ], unique: true,
      name: "idx_ad_unit_metrics_on_unit_date"
    # Range scans across many units filter by date first (§4.3).
    add_index :ad_unit_daily_metrics, [ :date, :ad_unit_id ],
      name: "idx_ad_unit_metrics_on_date_unit"
  end
end
