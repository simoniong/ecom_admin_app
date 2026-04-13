class AddReopenedReasonToTickets < ActiveRecord::Migration[8.0]
  def change
    add_column :tickets, :reopened_reason, :string
  end
end
