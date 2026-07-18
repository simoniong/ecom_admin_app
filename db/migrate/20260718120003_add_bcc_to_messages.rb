class AddBccToMessages < ActiveRecord::Migration[8.1]
  def change
    # Records the actual BCC address on a sent reply (mirrors the existing `cc`
    # column) — the audit trail for Trustpilot review invitations.
    add_column :messages, :bcc, :string
  end
end
