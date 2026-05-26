class CreateOrderLineItems < ActiveRecord::Migration[8.1]
  def change
    create_table :order_line_items, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :order_id, null: false
      t.uuid    :product_variant_id
      t.bigint  :shopify_line_item_id, null: false
      t.string  :sku_at_sale
      t.string  :title_at_sale
      t.integer :quantity, null: false
      t.decimal :unit_price, precision: 10, scale: 2
      t.decimal :unit_cost_snapshot, precision: 10, scale: 2
      t.string  :currency
      t.jsonb   :shopify_data, default: {}
      t.timestamps
    end
    add_index :order_line_items, [ :order_id, :shopify_line_item_id ], unique: true, name: "idx_line_items_order_shopify_id"
    add_index :order_line_items, :product_variant_id
    add_foreign_key :order_line_items, :orders
    add_foreign_key :order_line_items, :product_variants
  end
end
