class AddAgentApiKeyToEmailAccounts < ActiveRecord::Migration[8.1]
  def up
    add_column :email_accounts, :agent_api_key, :string

    EmailAccount.reset_column_information
    EmailAccount.where(agent_api_key: nil).find_each do |account|
      account.update_column(:agent_api_key, SecureRandom.urlsafe_base64(32))
    end

    change_column_null :email_accounts, :agent_api_key, false
    add_index :email_accounts, :agent_api_key, unique: true
  end

  def down
    remove_index :email_accounts, :agent_api_key
    remove_column :email_accounts, :agent_api_key
  end
end
