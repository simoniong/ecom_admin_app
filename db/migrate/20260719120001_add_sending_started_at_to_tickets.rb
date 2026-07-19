class AddSendingStartedAtToTickets < ActiveRecord::Migration[8.1]
  def change
    # In-flight claim marker: set under a row lock before the Gmail send so a
    # re-run after a mid-send crash won't resend, and concurrent workers serialize.
    add_column :tickets, :sending_started_at, :datetime
  end
end
