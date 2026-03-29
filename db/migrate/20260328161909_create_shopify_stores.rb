class CreateShopifyStores < ActiveRecord::Migration[8.1]
  def change
    create_table :shopify_stores, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :shop_domain, null: false
      t.text :access_token, null: false
      t.string :scopes
      t.datetime :installed_at

      t.timestamps
    end

    add_index :shopify_stores, [ :user_id, :shop_domain ], unique: true
  end
end
