class AddNewCustomerOrdersCountToShopifyDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_daily_metrics, :new_customer_orders_count, :integer, default: 0, null: false
  end
end
