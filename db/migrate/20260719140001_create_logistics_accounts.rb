class CreateLogisticsAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :logistics_accounts, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false, default: "raydo"
      t.string :username
      t.text   :password           # encrypted at the model layer
      t.string :customer_id         # cached from selectAuth
      t.string :customer_userid     # cached from selectAuth
      t.string :url1_base           # orders/query API base
      t.string :url2_base           # label-printing API base
      t.timestamps
    end
    add_index :logistics_accounts, [ :company_id, :provider ], unique: true
  end
end
