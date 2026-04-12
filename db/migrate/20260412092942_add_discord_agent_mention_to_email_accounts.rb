class AddDiscordAgentMentionToEmailAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :email_accounts, :discord_agent_mention, :string
  end
end
