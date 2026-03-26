class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets, id: :uuid do |t|
      t.references :email_account, null: false, foreign_key: true, type: :uuid
      t.string :gmail_thread_id, null: false
      t.string :subject
      t.string :customer_email, null: false
      t.string :customer_name
      t.integer :status, default: 0, null: false
      t.datetime :last_message_at
      t.timestamps
    end

    add_index :tickets, [ :email_account_id, :gmail_thread_id ], unique: true
    add_index :tickets, :status
    add_index :tickets, :last_message_at
  end
end
