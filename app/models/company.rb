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

  TRACKING_MODES = %w[new_only backfill].freeze
  DEFAULT_TRACKING_BACKFILL_DAYS = 30
  TRACKING_API_KEY_FORMAT = /\A[A-Za-z0-9]{32}\z/

  encrypts :tracking_api_key, deterministic: false

  scope :tracking_active, -> { where(tracking_enabled: true) }

  validates :name, presence: true
  validates :locale, inclusion: { in: AVAILABLE_LOCALES }
  validates :tracking_api_key,
            format: { with: TRACKING_API_KEY_FORMAT, message: :invalid_format },
            allow_blank: true
  validates :tracking_mode, inclusion: { in: TRACKING_MODES }, allow_blank: true
  validates :tracking_backfill_days,
            numericality: { only_integer: true, greater_than: 0 },
            allow_nil: true
  validate :tracking_api_key_required_when_enabled
  validate :tracking_mode_matches_api_key_presence
  validate :tracking_backfill_days_only_with_backfill_mode

  def tracking_api_key_configured?
    tracking_api_key.present?
  end

  def tracking_all_history?
    tracking_mode == "backfill" && tracking_backfill_days.nil?
  end

  def self.starts_at_for(mode:, days: nil, now: Time.current)
    case mode
    when "new_only" then now
    when "backfill" then days ? now - days.to_i.days : nil
    end
  end

  private

  def tracking_api_key_required_when_enabled
    return unless tracking_enabled?

    errors.add(:tracking_api_key, :required_when_enabled) if tracking_api_key.blank?
  end

  def tracking_mode_matches_api_key_presence
    if tracking_api_key.present? && tracking_mode.blank?
      errors.add(:tracking_mode, :required_with_api_key)
    elsif tracking_api_key.blank? && tracking_mode.present?
      errors.add(:tracking_mode, :forbidden_without_api_key)
    end
  end

  def tracking_backfill_days_only_with_backfill_mode
    return if tracking_backfill_days.nil?
    return if tracking_mode == "backfill"

    errors.add(:tracking_backfill_days, :only_with_backfill_mode)
  end
end
