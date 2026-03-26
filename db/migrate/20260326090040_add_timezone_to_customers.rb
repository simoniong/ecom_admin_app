class AddTimezoneToCustomers < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :timezone, :string, default: "UTC", null: false
  end
end
