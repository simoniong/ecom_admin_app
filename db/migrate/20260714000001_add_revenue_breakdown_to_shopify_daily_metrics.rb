class AddRevenueBreakdownToShopifyDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    change_table :shopify_daily_metrics, bulk: true do |t|
      t.decimal :gross_revenue,    precision: 12, scale: 2, default: 0, null: false
      t.decimal :refunds,          precision: 12, scale: 2, default: 0, null: false
      t.decimal :total_tax,        precision: 12, scale: 2, default: 0, null: false
      t.decimal :transaction_fees, precision: 12, scale: 2, default: 0, null: false
    end
  end
end
