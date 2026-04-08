class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.integer :role, null: false, default: 0
      t.jsonb :permissions, null: false, default: []
      t.timestamps
    end

    add_index :memberships, [ :company_id, :user_id ], unique: true
  end
end
