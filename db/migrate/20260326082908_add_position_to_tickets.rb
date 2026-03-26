class AddPositionToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :tickets, :position, :integer, default: 0, null: false
    add_index :tickets, [ :status, :position ]
  end
end
