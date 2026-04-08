class CreateInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :invitations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid
      t.references :invited_by, null: false, foreign_key: { to_table: :users }, type: :uuid
      t.string :email, null: false
      t.integer :role, null: false, default: 0
      t.jsonb :permissions, null: false, default: []
      t.string :token, null: false
      t.datetime :accepted_at
      t.timestamps
    end

    add_index :invitations, :token, unique: true
    add_index :invitations, [ :company_id, :email ], unique: true, where: "accepted_at IS NULL"
  end
end
