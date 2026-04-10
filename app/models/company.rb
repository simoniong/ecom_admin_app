class Company < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :shopify_stores, dependent: :destroy
  has_many :ad_accounts, dependent: :destroy
  has_many :email_accounts, dependent: :destroy
  has_many :campaign_display_templates, dependent: :destroy
  has_many :invitations, dependent: :destroy
  has_many :shipping_reminder_rules, dependent: :destroy
  has_one :shipping_reminder_setting, dependent: :destroy

  AVAILABLE_LOCALES = I18n.available_locales.map(&:to_s).freeze

  validates :name, presence: true
  validates :locale, inclusion: { in: AVAILABLE_LOCALES }
end
