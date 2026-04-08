class AddNotNullToCompanyIdColumns < ActiveRecord::Migration[8.1]
  def change
    change_column_null :shopify_stores, :company_id, false
    change_column_null :ad_accounts, :company_id, false
    change_column_null :email_accounts, :company_id, false
    change_column_null :campaign_display_templates, :company_id, false
  end
end
