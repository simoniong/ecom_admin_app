class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :recoverable, :rememberable,
         :validatable, :lockable

  AVAILABLE_LOCALES = I18n.available_locales.map(&:to_s).freeze

  # Allow-list of emails that may create new Companies. Hard-coded because
  # Company creation is an ops action performed by the platform operator,
  # not a self-service flow.
  COMPANY_CREATOR_EMAILS = %w[manin.iong@gmail.com].freeze

  validates :locale, inclusion: { in: AVAILABLE_LOCALES }, allow_nil: true

  has_many :memberships, dependent: :destroy
  has_many :companies, through: :memberships
  has_many :groups, through: :memberships

  has_many :email_accounts, dependent: :destroy
  has_many :shopify_stores, dependent: :destroy
  has_many :tickets, through: :email_accounts
  has_many :ad_accounts, dependent: :destroy
  has_many :campaign_display_templates, dependent: :destroy

  def membership_for(company)
    memberships.find_by(company: company)
  end

  def owned_companies
    companies.where(memberships: { role: :owner })
  end

  def can_create_companies?
    COMPANY_CREATOR_EMAILS.include?(email.to_s.downcase)
  end
end
