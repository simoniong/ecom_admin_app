class AddAgentApiKeyToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :agent_api_key, :string
    add_index  :companies, :agent_api_key, unique: true
  end
end
