class ShopifyStore < ApplicationRecord
  belongs_to :user
  has_many :email_accounts, dependent: :nullify

  encrypts :access_token, deterministic: false

  validates :shop_domain, presence: true, uniqueness: true,
            format: { with: /\A[\w-]+\.myshopify\.com\z/, message: "must be a valid myshopify.com domain" }
  validates :access_token, presence: true
end
