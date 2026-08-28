class AddCnyShippingCostsToOrders < ActiveRecord::Migration[8.1]
  # estimated/actual_shipping_cost are stored in the store's currency, but the
  # rate cards price in CNY and the parcels are billed in CNY. Every CNY figure
  # on the variance report was therefore a back-conversion of a rounded
  # store-currency number, so an estimate the rate card put at ¥132.92 rendered
  # as ¥132.95 in the order row while the basis panel beside it showed ¥132.92.
  #
  # Nullable: readers COALESCE back to `store_currency * cost_fx_rate` so there
  # is no broken window between deploying this and running the backfill.
  def change
    add_column :orders, :estimated_shipping_cost_cny, :decimal, precision: 12, scale: 2
    add_column :orders, :actual_shipping_cost_cny, :decimal, precision: 12, scale: 2
  end
end
