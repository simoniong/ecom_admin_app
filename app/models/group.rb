class Group < ApplicationRecord
  belongs_to :company
  has_many :memberships, dependent: :nullify
  has_many :users, through: :memberships
  has_many :shopify_stores, dependent: :nullify
  has_many :ad_accounts, dependent: :nullify
  has_many :email_accounts, dependent: :nullify
  has_many :invitations, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :company_id, case_sensitive: false }
end
