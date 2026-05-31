class CreateProductVariants < ActiveRecord::Migration[8.1]
  def change
    create_table :product_variants, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :product_id, null: false
      t.bigint  :shopify_variant_id, null: false
      t.bigint  :shopify_inventory_item_id
      t.string  :sku
      t.string  :title
      t.decimal :price, precision: 10, scale: 2
      t.string  :currency
      t.decimal :shopify_cost, precision: 10, scale: 2
      t.decimal :unit_cost, precision: 10, scale: 2
      t.decimal :shopify_weight_grams, precision: 12, scale: 3
      t.decimal :weight_grams, precision: 12, scale: 3
      t.jsonb   :shopify_data, default: {}
      t.timestamps
    end
    add_index :product_variants, [ :product_id, :shopify_variant_id ], unique: true, name: "idx_variants_product_shopify_id"
    add_index :product_variants, :sku
    add_index :product_variants, :shopify_inventory_item_id
    add_foreign_key :product_variants, :products
  end
end
