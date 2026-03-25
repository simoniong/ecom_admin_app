class CreateEmailAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :email_accounts, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :email, null: false
      t.string :google_uid, null: false
      t.text :access_token, null: false
      t.text :refresh_token, null: false
      t.datetime :token_expires_at
      t.text :scopes
      t.timestamps
    end

    add_index :email_accounts, :google_uid, unique: true
    add_index :email_accounts, [ :user_id, :email ], unique: true
  end
end
