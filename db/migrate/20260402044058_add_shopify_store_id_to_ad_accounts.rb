class AddShopifyStoreIdToAdAccounts < ActiveRecord::Migration[8.1]
  def change
    add_reference :ad_accounts, :shopify_store, null: true, foreign_key: true, type: :uuid
  end
end
