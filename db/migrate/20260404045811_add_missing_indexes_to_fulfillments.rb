class AddMissingIndexesToFulfillments < ActiveRecord::Migration[8.1]
  def change
    add_index :fulfillments, :destination_carrier
    add_index :fulfillments, :transit_days
  end
end
