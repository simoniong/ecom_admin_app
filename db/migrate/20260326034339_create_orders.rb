class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders, id: :uuid do |t|
      t.references :customer, null: false, foreign_key: true, type: :uuid
      t.bigint :shopify_order_id, null: false
      t.string :email
      t.string :name
      t.decimal :total_price, precision: 10, scale: 2
      t.string :currency
      t.string :financial_status
      t.string :fulfillment_status
      t.datetime :ordered_at
      t.jsonb :shopify_data, default: {}
      t.timestamps
    end

    add_index :orders, :shopify_order_id, unique: true
  end
end
