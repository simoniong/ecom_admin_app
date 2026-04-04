class AddShippingFieldsToFulfillments < ActiveRecord::Migration[8.1]
  def change
    add_column :fulfillments, :tracking_status, :string
    add_column :fulfillments, :tracking_sub_status, :string
    add_column :fulfillments, :origin_country, :string
    add_column :fulfillments, :destination_country, :string
    add_column :fulfillments, :origin_carrier, :string
    add_column :fulfillments, :destination_carrier, :string
    add_column :fulfillments, :transit_days, :integer
    add_column :fulfillments, :shipped_at, :datetime
    add_column :fulfillments, :delivered_at, :datetime
    add_column :fulfillments, :last_event_at, :datetime
    add_column :fulfillments, :latest_event_description, :string
    add_column :fulfillments, :tags, :string, array: true, default: []

    add_index :fulfillments, :tracking_status
    add_index :fulfillments, :destination_country
    add_index :fulfillments, :origin_carrier
    add_index :fulfillments, :shipped_at
    add_index :fulfillments, :delivered_at
    add_index :fulfillments, :last_event_at
  end
end
