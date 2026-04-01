class AddTimezoneToAdAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_accounts, :timezone, :string, default: "UTC", null: false
  end
end
