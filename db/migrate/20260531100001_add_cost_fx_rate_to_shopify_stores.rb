class AddCostFxRateToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :cost_fx_rate, :decimal, precision: 10, scale: 4
  end
end
