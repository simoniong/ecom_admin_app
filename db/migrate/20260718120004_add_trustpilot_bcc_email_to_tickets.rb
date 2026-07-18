class AddTrustpilotBccEmailToTickets < ActiveRecord::Migration[8.1]
  def change
    # Snapshot of the store's Trustpilot address, resolved when the agent
    # confirms the draft. The send job uses this immutable value rather than
    # re-resolving the (mutable) email-account -> store association at send time.
    add_column :tickets, :trustpilot_bcc_email, :string
  end
end
