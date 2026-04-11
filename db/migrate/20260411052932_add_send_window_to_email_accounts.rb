class AddSendWindowToEmailAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :email_accounts, :send_window_from_hour, :integer, default: 8, null: false
    add_column :email_accounts, :send_window_from_minute, :integer, default: 0, null: false
    add_column :email_accounts, :send_window_to_hour, :integer, default: 22, null: false
    add_column :email_accounts, :send_window_to_minute, :integer, default: 0, null: false
  end
end
