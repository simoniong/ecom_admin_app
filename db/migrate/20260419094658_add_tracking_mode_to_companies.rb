class AddTrackingModeToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :tracking_mode, :string
    add_column :companies, :tracking_starts_at, :datetime
  end
end
