class AddTrustpilotBccEmailToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    # Each store has its own unique Trustpilot invite address; BCC'ing it on a
    # reply triggers Trustpilot to email that customer a review invitation.
    add_column :shopify_stores, :trustpilot_bcc_email, :string
  end
end
