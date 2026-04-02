class AdCampaignDailyMetric < ApplicationRecord
  belongs_to :ad_campaign

  validates :date, presence: true, uniqueness: { scope: :ad_campaign_id }
  validates :spend, numericality: { greater_than_or_equal_to: 0 }

  scope :for_date_range, ->(range) { where(date: range) }
end
