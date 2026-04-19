class AdAccount < ApplicationRecord
  include GroupAssignable

  belongs_to :user
  belongs_to :company
  belongs_to :shopify_store, optional: true
  has_many :ad_campaigns, dependent: :destroy
  has_many :ad_daily_metrics, dependent: :destroy

  encrypts :access_token, deterministic: false

  validates :platform, presence: true, inclusion: { in: %w[meta] }
  validates :account_id, presence: true, uniqueness: { scope: [ :platform, :user_id ] }
  validates :access_token, presence: true

  scope :meta, -> { where(platform: "meta") }

  def token_expired?
    token_expires_at.present? && token_expires_at < Time.current
  end

  def token_expiring_soon?
    token_expires_at.present? && token_expires_at < 7.days.from_now
  end
end
