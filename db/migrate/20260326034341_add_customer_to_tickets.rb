class AddCustomerToTickets < ActiveRecord::Migration[8.1]
  def change
    add_reference :tickets, :customer, foreign_key: true, type: :uuid, null: true
  end
end
