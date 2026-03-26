class AddSyncFieldsToEmailAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :email_accounts, :last_synced_at, :datetime
    add_column :email_accounts, :last_history_id, :bigint
  end
end
