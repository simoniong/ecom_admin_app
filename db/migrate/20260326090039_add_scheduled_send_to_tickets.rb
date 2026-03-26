class AddScheduledSendToTickets < ActiveRecord::Migration[8.1]
  def change
    add_column :tickets, :scheduled_send_at, :datetime
    add_column :tickets, :scheduled_job_id, :string
    add_index :tickets, :scheduled_send_at
  end
end
