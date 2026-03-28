class CreateAdAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_accounts, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :platform, null: false, default: "meta"
      t.string :account_id, null: false
      t.string :account_name
      t.text :access_token, null: false
      t.datetime :token_expires_at

      t.timestamps
    end

    add_index :ad_accounts, [ :platform, :account_id ], unique: true
  end
end
