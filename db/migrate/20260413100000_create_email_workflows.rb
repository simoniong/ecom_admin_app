class CreateEmailWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :email_workflows, id: :uuid do |t|
      t.references :shopify_store, null: false, foreign_key: true, type: :uuid
      t.string :trigger_event, null: false
      t.boolean :enabled, default: true, null: false

      t.timestamps
    end

    add_index :email_workflows, [ :shopify_store_id, :trigger_event ], unique: true
  end
end
