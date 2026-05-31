class RemoveShopifyCostAndWeightFromProductVariants < ActiveRecord::Migration[8.1]
  def change
    remove_index  :product_variants, :shopify_inventory_item_id
    remove_column :product_variants, :shopify_cost,              :decimal, precision: 10, scale: 2
    remove_column :product_variants, :shopify_weight_grams,      :decimal, precision: 12, scale: 3
    remove_column :product_variants, :shopify_inventory_item_id, :bigint
  end
end
