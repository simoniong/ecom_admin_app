class Membership < ApplicationRecord
  belongs_to :company
  belongs_to :user

  enum :role, { member: 0, owner: 1 }

  validates :company_id, uniqueness: { scope: :user_id }
  validates :role, presence: true

  # Dashboard is always granted — not listed here since it's not a selectable permission
  AVAILABLE_PERMISSIONS = %w[
    orders shipments tickets ad_campaigns
    shopify_stores ad_accounts email_accounts
    shipping_reminder_rules
  ].freeze

  def has_permission?(controller_name)
    owner? || controller_name.to_s == "dashboard" || permissions.include?(controller_name.to_s)
  end
end
