class Company < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :shopify_stores, dependent: :destroy
  has_many :ad_accounts, dependent: :destroy
  has_many :email_accounts, dependent: :destroy
  has_many :campaign_display_templates, dependent: :destroy
  has_many :invitations, dependent: :destroy

  validates :name, presence: true
end
