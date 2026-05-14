class ShopifyStore < ApplicationRecord
  include GroupAssignable

  belongs_to :user
  belongs_to :company
  has_many :email_accounts, dependent: :nullify
  has_many :ad_accounts, dependent: :nullify
  has_many :customers, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :email_workflows, dependent: :destroy

  encrypts :access_token, deterministic: false
  encrypts :client_secret, deterministic: false

  validates :shop_domain, presence: true, uniqueness: true,
            format: { with: /\A[\w-]+\.myshopify\.com\z/, message: "must be a valid myshopify.com domain" }
  validates :access_token, presence: true
  validates :client_id, presence: true
  validates :client_secret, presence: true

  # One-time backfill invoked by the add_credentials_to_shopify_stores migration.
  # Copies the legacy global app credentials onto any store still missing them.
  # Goes through the model (not update_all) so client_secret is encrypted, but
  # saves with validations off: pre-existing rows may fail unrelated validations
  # (e.g. a nil group_id once the company has groups) that must not block the
  # backfill. The legacy ENV vars are only required when a store actually needs
  # backfilling, so post-deploy migrations on an empty DB don't fail needlessly.
  def self.backfill_credentials_from_env!
    scope = where(client_id: nil).or(where(client_secret: nil))
    return if scope.none?

    client_id = ENV["SHOPIFY_CLIENT_ID"]
    client_secret = ENV["SHOPIFY_CLIENT_SECRET"]

    if client_id.blank? || client_secret.blank?
      raise "backfill_credentials_from_env!: SHOPIFY_CLIENT_ID / SHOPIFY_CLIENT_SECRET must be set"
    end

    scope.find_each do |store|
      store.assign_attributes(client_id: client_id, client_secret: client_secret)
      store.save!(validate: false)
    end
  end

  def active_timezone
    ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
  end
end
