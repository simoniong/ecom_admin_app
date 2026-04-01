class CreateShopifyDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :shopify_daily_metrics, id: :uuid do |t|
      t.uuid :shopify_store_id, null: false
      t.date :date, null: false
      t.integer :sessions, default: 0
      t.integer :orders_count, default: 0
      t.decimal :revenue, precision: 12, scale: 2, default: 0
      t.decimal :conversion_rate, precision: 5, scale: 4, default: 0
      t.timestamps
    end

    add_index :shopify_daily_metrics, %i[shopify_store_id date], unique: true, name: "idx_shopify_metrics_store_date"
    add_index :shopify_daily_metrics, :shopify_store_id
  end
end
