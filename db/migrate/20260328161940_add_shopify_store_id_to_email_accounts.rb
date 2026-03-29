class AddShopifyStoreIdToEmailAccounts < ActiveRecord::Migration[8.1]
  def change
    add_reference :email_accounts, :shopify_store, type: :uuid, foreign_key: true, null: true
  end
end
