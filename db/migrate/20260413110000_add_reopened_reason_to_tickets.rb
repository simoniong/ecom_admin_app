class AddReopenedReasonToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :tickets, :reopened_reason, :string
    Ticket.reset_column_information
    Ticket.where(reopened_reason: nil).update_all(reopened_reason: "customer_inquiry")
  end
end
