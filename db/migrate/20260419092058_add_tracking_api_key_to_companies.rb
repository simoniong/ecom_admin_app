class AddTrackingApiKeyToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :tracking_api_key, :text
  end
end
