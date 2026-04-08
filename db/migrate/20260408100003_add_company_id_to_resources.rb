class AddCompanyIdToResources < ActiveRecord::Migration[8.1]
  def change
    add_reference :shopify_stores, :company, type: :uuid, foreign_key: true
    add_reference :ad_accounts, :company, type: :uuid, foreign_key: true
    add_reference :email_accounts, :company, type: :uuid, foreign_key: true
    add_reference :campaign_display_templates, :company, type: :uuid, foreign_key: true
  end
end
