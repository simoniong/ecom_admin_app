class CampaignDisplayTemplate < ApplicationRecord
  belongs_to :user

  validates :name, presence: true
  validates :visible_columns, presence: true

  ALL_COLUMNS = %w[
    ad_account daily_budget impressions clicks ctr cpc
    add_to_cart atc_click_rate cost_per_atc
    checkout_initiated checkout_atc_rate cost_per_checkout
    purchases purchase_checkout_rate purchase_click_rate cost_per_purchase
    spend conversion_value roas
  ].freeze

  scope :by_last_active, -> { order(last_active_at: :desc, created_at: :desc) }

  def touch_active!
    update!(last_active_at: Time.current)
  end

  def column_visible?(column)
    visible_columns.include?(column.to_s)
  end
end
