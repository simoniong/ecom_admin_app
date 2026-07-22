class AddTrackingApplicationFieldsToPackages < ActiveRecord::Migration[8.1]
  def change
    add_column :packages, :raydo_order_id, :string
    add_column :packages, :tracking_number, :string
    add_column :packages, :carrier, :string
    add_column :packages, :application_message, :text
    add_column :packages, :applied_at, :datetime
  end
end
