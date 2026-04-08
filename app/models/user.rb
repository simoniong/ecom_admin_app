class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :recoverable, :rememberable,
         :validatable, :lockable

  has_many :memberships, dependent: :destroy
  has_many :companies, through: :memberships

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
end
