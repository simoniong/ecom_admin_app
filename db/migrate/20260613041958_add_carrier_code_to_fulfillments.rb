class AddCarrierCodeToFulfillments < ActiveRecord::Migration[8.1]
  def change
    add_column :fulfillments, :carrier_code, :integer
  end
end
