class ShopifyStore < ApplicationRecord
  include GroupAssignable

  FULFILLMENT_WRITE_SCOPE = "write_merchant_managed_fulfillment_orders"

  belongs_to :user
  belongs_to :company
  has_many :email_accounts, dependent: :nullify
  has_many :ad_accounts, dependent: :nullify
  has_many :customers, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :products, dependent: :destroy
  has_many :email_workflows, dependent: :destroy
  has_many :packages, dependent: :destroy

  encrypts :access_token, deterministic: false
  encrypts :client_secret, deterministic: false

  validates :shop_domain, presence: true, uniqueness: true,
            format: { with: /\A[\w-]+\.myshopify\.com\z/, message: "must be a valid myshopify.com domain" }
  validates :access_token, presence: true
  validates :client_id, presence: true
  validates :client_secret, presence: true
  validates :cost_fx_rate, numericality: { greater_than: 0, allow_nil: true }
  validates :default_service_type, inclusion: { in: ShippingRateCardVersion::SERVICE_TYPES }, allow_blank: true
  validates :trustpilot_bcc_email,
            format: { with: /\A[^@\s]+@invite\.trustpilot\.com\z/, message: :invalid_trustpilot_address },
            allow_blank: true
  validates :package_prefix, :package_number_start, presence: true, if: :packing_enabled?
  validates :package_number_start, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :packing_identity_locked_once_used

  before_save :set_packing_enabled_at, if: -> { will_save_change_to_packing_enabled? && packing_enabled? }

  def active_timezone
    ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
  end

  def packing_settings_locked?
    packages.exists?
  end

  # Human-friendly label for the store. Falls back to the myshopify domain
  # for stores bound before the Shopify shop name was captured.
  def display_name
    name.presence || shop_domain
  end

  # Compact label that drops the ".myshopify.com" suffix when no name is set.
  def short_name
    name.presence || shop_domain.sub(".myshopify.com", "")
  end

  def fulfillment_write_scope?
    scopes.to_s.split(",").map(&:strip).include?(FULFILLMENT_WRITE_SCOPE)
  end

  private

  # Stamps the moment packing is turned ON so PackageAutoBuilder can refuse
  # to backfill packages for orders that existed/were placed before the
  # switch was flipped. Only set on the false->true transition; toggling
  # off and back on again re-stamps it (each enable is treated as a fresh
  # "clean start" boundary), and turning off never clears it.
  def set_packing_enabled_at
    self.packing_enabled_at = Time.current
  end

  def packing_identity_locked_once_used
    return unless persisted? && packing_settings_locked?
    if will_save_change_to_package_prefix? || will_save_change_to_package_number_start?
      errors.add(:package_prefix, :locked_after_first_package) if will_save_change_to_package_prefix?
      errors.add(:package_number_start, :locked_after_first_package) if will_save_change_to_package_number_start?
    end
  end
end
