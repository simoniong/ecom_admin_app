class AddCredentialsToShopifyStores < ActiveRecord::Migration[8.1]
  def up
    add_column :shopify_stores, :client_id, :string
    add_column :shopify_stores, :client_secret, :text
    # When this migration first ran on staging/production it also backfilled
    # existing stores from the legacy global ENV credentials. That step has
    # since been removed: it depended on model code that no longer exists, and
    # any database where this migration has not run yet is empty — a fresh DB
    # has no stores to backfill.
  end

  def down
    remove_column :shopify_stores, :client_secret
    remove_column :shopify_stores, :client_id
  end
end
