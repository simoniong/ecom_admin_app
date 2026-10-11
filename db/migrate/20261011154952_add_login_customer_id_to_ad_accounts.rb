class AddLoginCustomerIdToAdAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_accounts, :login_customer_id, :string
  end
end
