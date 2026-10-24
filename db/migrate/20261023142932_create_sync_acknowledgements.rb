class CreateSyncAcknowledgements < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_acknowledgements, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :company, null: false, foreign_key: true, type: :uuid
      t.string :source, null: false
      t.string :signature, null: false
      t.datetime :acknowledged_at, null: false

      t.timestamps
    end

    add_index :sync_acknowledgements, [ :user_id, :company_id, :source ], unique: true
  end
end
