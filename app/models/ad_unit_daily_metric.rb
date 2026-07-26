class AdUnitDailyMetric < ApplicationRecord
  belongs_to :ad_unit

  validates :date, presence: true, uniqueness: { scope: :ad_unit_id }
  validates :spend, numericality: { greater_than_or_equal_to: 0 }
end
