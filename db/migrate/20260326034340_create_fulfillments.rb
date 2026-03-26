class CreateFulfillments < ActiveRecord::Migration[8.1]
  def change
    create_table :fulfillments, id: :uuid do |t|
      t.references :order, null: false, foreign_key: true, type: :uuid
      t.bigint :shopify_fulfillment_id, null: false
      t.string :status
      t.string :tracking_number
      t.string :tracking_company
      t.string :tracking_url
      t.jsonb :tracking_details, default: {}
      t.jsonb :shopify_data, default: {}
      t.timestamps
    end

    add_index :fulfillments, :shopify_fulfillment_id, unique: true
    add_index :fulfillments, :tracking_number
  end
end
