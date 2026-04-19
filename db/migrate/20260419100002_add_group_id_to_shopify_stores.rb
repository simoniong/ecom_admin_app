class AddGroupIdToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_reference :shopify_stores, :group, type: :uuid, foreign_key: true, null: true, index: true
  end
end
