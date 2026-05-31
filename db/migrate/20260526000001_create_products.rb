class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :shopify_store_id, null: false
      t.bigint  :shopify_product_id, null: false
      t.string  :title
      t.string  :handle
      t.string  :status
      t.string  :image_url
      t.jsonb   :shopify_data, default: {}
      t.timestamps
    end
    add_index :products, [ :shopify_store_id, :shopify_product_id ], unique: true, name: "idx_products_store_shopify_id"
    add_index :products, :shopify_store_id
    add_foreign_key :products, :shopify_stores
  end
end
