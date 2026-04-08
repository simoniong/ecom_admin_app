class Membership < ApplicationRecord
  belongs_to :company
  belongs_to :user

  enum :role, { member: 0, owner: 1 }

  validates :company_id, uniqueness: { scope: :user_id }
  validates :role, presence: true

  AVAILABLE_PERMISSIONS = %w[
    dashboard orders shipments tickets ad_campaigns
    shopify_stores ad_accounts email_accounts
  ].freeze

  def has_permission?(controller_name)
    owner? || permissions.include?(controller_name.to_s)
  end
end
