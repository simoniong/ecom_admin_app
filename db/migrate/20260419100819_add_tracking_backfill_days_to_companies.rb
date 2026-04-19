class AddTrackingBackfillDaysToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :tracking_backfill_days, :integer
  end
end
