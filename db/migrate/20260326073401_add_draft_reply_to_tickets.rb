class AddDraftReplyToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :tickets, :draft_reply, :text
    add_column :tickets, :draft_reply_at, :datetime
  end
end
