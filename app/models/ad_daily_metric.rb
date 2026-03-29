class AdDailyMetric < ApplicationRecord
  belongs_to :ad_account

  validates :date, presence: true, uniqueness: { scope: :ad_account_id }
  validates :spend, numericality: { greater_than_or_equal_to: 0 }

  scope :for_date_range, ->(range) { where(date: range) }
  scope :for_account, ->(account) { where(ad_account: account) }
end
