class AdUnit < ApplicationRecord
  belongs_to :ad_account
  belongs_to :ad_creative, optional: true
  belongs_to :ad_campaign, optional: true
  has_many :ad_unit_daily_metrics, dependent: :destroy

  validates :ad_id, presence: true, uniqueness: { scope: :ad_account_id }
  validates :status, presence: true, inclusion: { in: %w[active paused deleted] }

  scope :attributable, -> { where(multi_asset: false).where.not(ad_creative_id: nil) }
end
