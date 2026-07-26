class CreatePackageItems < ActiveRecord::Migration[8.1]
  def change
    create_table :package_items, id: :uuid do |t|
      t.references :package, type: :uuid, null: false, foreign_key: true
      t.references :product_variant, type: :uuid, null: true, foreign_key: true
      t.references :order_line_item, type: :uuid, null: true, foreign_key: true
      t.string  :sku
      t.string  :title
      t.integer :quantity, null: false
      t.timestamps
    end
  end
end
