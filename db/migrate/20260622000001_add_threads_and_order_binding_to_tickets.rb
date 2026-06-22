class AddThreadsAndOrderBindingToTickets < ActiveRecord::Migration[8.1]
  def change
    # gmail_thread_id becomes nullable; uniqueness only when present.
    change_column_null :tickets, :gmail_thread_id, true
    remove_index :tickets, name: "index_tickets_on_email_account_id_and_gmail_thread_id"
    add_index :tickets, [ :email_account_id, :gmail_thread_id ],
              unique: true,
              where: "gmail_thread_id IS NOT NULL",
              name: "index_tickets_on_email_account_id_and_gmail_thread_id"

    add_column :tickets, :initiated_by, :integer, null: false, default: 0
    add_reference :tickets, :order, type: :uuid, null: true, foreign_key: true, index: true
  end
end
