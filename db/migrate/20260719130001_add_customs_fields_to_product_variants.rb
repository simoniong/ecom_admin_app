class AddCustomsFieldsToProductVariants < ActiveRecord::Migration[8.1]
  def change
    # Per-SKU customs declaration. Declared weight reuses the existing
    # weight_grams column (shared with shipping-cost calc), not a new field.
    add_column :product_variants, :customs_name_zh, :string
    add_column :product_variants, :customs_name_en, :string
    add_column :product_variants, :declared_value_usd, :decimal, precision: 10, scale: 2
    add_column :product_variants, :hs_code, :string
    add_column :product_variants, :import_hs_code, :string
  end
end
