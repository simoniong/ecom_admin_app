class AddShippingCostsToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :estimated_shipping_cost, :decimal, precision: 10, scale: 2
    add_column :orders, :actual_shipping_cost,    :decimal, precision: 10, scale: 2
  end
end
