class CreateCustomers < ActiveRecord::Migration[8.1]
  def change
    create_table :customers, id: :uuid do |t|
      t.bigint :shopify_customer_id, null: false
      t.string :email
      t.string :first_name
      t.string :last_name
      t.string :phone
      t.jsonb :shopify_data, default: {}
      t.timestamps
    end

    add_index :customers, :shopify_customer_id, unique: true
    add_index :customers, :email
  end
end
