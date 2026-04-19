class AddTrackingEnabledToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :tracking_enabled, :boolean, default: false, null: false
  end
end
