class AddCredentialsToShopifyStores < ActiveRecord::Migration[8.1]
  def up
    add_column :shopify_stores, :client_id, :string
    add_column :shopify_stores, :client_secret, :text

    ShopifyStore.reset_column_information
    ShopifyStore.backfill_credentials_from_env!
  end

  def down
    remove_column :shopify_stores, :client_secret
    remove_column :shopify_stores, :client_id
  end
end
