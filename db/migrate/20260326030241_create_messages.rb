class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages, id: :uuid do |t|
      t.references :ticket, null: false, foreign_key: true, type: :uuid
      t.string :gmail_message_id, null: false
      t.string :from, null: false
      t.string :to
      t.string :cc
      t.string :subject
      t.text :body
      t.datetime :sent_at
      t.bigint :gmail_internal_date
      t.timestamps
    end

    add_index :messages, :gmail_message_id, unique: true
    add_index :messages, [ :ticket_id, :sent_at ]
  end
end
