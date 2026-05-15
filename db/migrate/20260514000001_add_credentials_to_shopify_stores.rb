class AddCredentialsToShopifyStores < ActiveRecord::Migration[8.1]
  def up
    add_column :shopify_stores, :client_id, :string
    add_column :shopify_stores, :client_secret, :text
    # When this migration first ran on staging/production it also backfilled
    # existing stores from the legacy global SHOPIFY_CLIENT_ID/SECRET via
    # ShopifyStore.backfill_credentials_from_env!. That helper and its call
    # here have since been removed: every environment with data has already
    # run this migration with the backfill, and any future run is on a fresh
    # DB with no stores to backfill.
  end

  def down
    remove_column :shopify_stores, :client_secret
    remove_column :shopify_stores, :client_id
  end
end
