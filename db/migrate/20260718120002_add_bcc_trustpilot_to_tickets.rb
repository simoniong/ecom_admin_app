class AddBccTrustpilotToTickets < ActiveRecord::Migration[8.1]
  def change
    # Captured when the agent confirms the draft; read later at send time.
    add_column :tickets, :bcc_trustpilot, :boolean, null: false, default: false
  end
end
